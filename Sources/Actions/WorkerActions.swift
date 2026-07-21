import Foundation
import GRDB
import Hummingbird
import Logging

// Phase 2 migration: action definitions for /api/worker routes.
// Handler logic is duplicated from WorkerRoutes.swift.

let workerLogger = Logging.Logger(label: "sonata.worker")

/// Returned when worker_set_status refuses a clearCurrentEvent because the slot
/// does not hold what the caller expected. Carries the id actually held so the
/// caller can tell "someone else already cleared it" from "I was about to eat a
/// freshly dispatched event."
struct ClearRefusedResponse: Encodable {
    let success = false
    let cleared = false
    let currentEventId: String?
    let reason = "currentEventId does not match expectedEventId"
}

/// Compare-and-swap predicate for worker_set_status(clearCurrentEvent).
///
/// Pulled out of the handler so the 2026-07-20 race is pinned by a test rather
/// than by reading the SQL. `held` is what the worker row currently points at
/// (nil when empty); `expected` is what the caller believes it holds.
///
/// The unguarded case (`force`) is retained deliberately: clearing a genuinely
/// mismatched slot is what this endpoint was built for. It is opt-in and logged,
/// so the dangerous shape stays reachable but never accidental.
func clearCurrentEventShouldProceed(held: String?, expected: String?, force: Bool) -> Bool {
    if force { return true }
    guard let expected else { return false }
    return held == expected
}

// MARK: - Stuck-busy reconcile (Path #1 root fix)

/// Free any worker still pinned (currentEventId == eventId) to an event that is
/// NOT live — i.e. already terminal (completed/failed/cancelled) or whose row is
/// gone. Called from the owner-guard reject branch of worker_event_complete /
/// worker_event_fail.
///
/// Why this is the recurring "stuck busy" root cause (2026-07-17): the F4
/// owner-guard intentionally skips the event/task side effects when a completion
/// arrives from a caller that no longer owns the event (stale zombie, or the
/// event was reaped/re-dispatched). But it also skipped freeing the CALLER's own
/// worker row, leaving `currentEventId` pinned and the worker `busy` forever.
/// Nothing else recovered it: reclaimStrandedEvents only fires while the event is
/// still `assigned`, and sweepOrphanedEvents only when the worker no longer
/// exists — a live, fresh-heartbeat worker pinned to a *terminal* event fell
/// through both. This was hand-unstuck per-incident with worker_set_status.
///
/// Safety: the normal completion path flips the event terminal AND frees the
/// worker in the SAME transaction, so no worker is ever legitimately pinned to a
/// non-live event. If instead the event is still live ('assigned'/'pending' to a
/// genuine re-dispatch), we leave every worker alone — the F4 owner-guard owns
/// that case. Returns the number of workers reconciled.
@discardableResult
func reconcilePinnedWorkers(eventId: String, in db: Database) throws -> Int {
    let liveStatus = try String.fetchOne(db,
        sql: "SELECT status FROM workerEvents WHERE id = ?",
        arguments: [eventId])
    // 'assigned'/'pending' = a live re-dispatch owns it → don't touch.
    // terminal ('completed'/'failed'/'cancelled') or nil (row gone) → reconcile.
    if liveStatus == "assigned" || liveStatus == "pending" { return 0 }
    try db.execute(sql: """
        UPDATE workers SET
            status = CASE WHEN status = 'draining' THEN 'draining' ELSE 'idle' END,
            currentEventId = NULL,
            currentEventTokens = NULL,
            currentSlug = NULL,
            currentCacheReadTokens = NULL,
            currentInputTokens = NULL,
            currentPromptHash = NULL,
            currentSessionLabel = NULL,
            currentCwdBasename = NULL
        WHERE currentEventId = ?
    """, arguments: [eventId])
    return db.changesCount
}

// MARK: - Response shapes specific to actions

private struct WorkerListItem: Encodable {
    let _id: String
    let workerId: String
    let sessionLabel: String
    let status: String
    let capabilities: String  // raw JSON string, matching existing route behaviour
    let lastHeartbeat: Int64
    let currentEventId: String
    let registeredAt: Int64
    let currentTask: String?
    let assignedAt: Int64?
    let currentEventTokens: Int64?
    let currentSlug: String?
    let currentCacheReadTokens: Int64?
    let currentInputTokens: Int64?
    let currentContextTokens: Int64?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(workerId, forKey: .workerId)
        try c.encode(sessionLabel, forKey: .sessionLabel)
        try c.encode(status, forKey: .status)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(lastHeartbeat, forKey: .lastHeartbeat)
        try c.encode(currentEventId, forKey: .currentEventId)
        try c.encode(registeredAt, forKey: .registeredAt)
        try c.encodeIfPresent(currentTask, forKey: .currentTask)
        try c.encodeIfPresent(assignedAt, forKey: .assignedAt)
        try c.encodeIfPresent(currentEventTokens, forKey: .currentEventTokens)
        try c.encodeIfPresent(currentSlug, forKey: .currentSlug)
        try c.encodeIfPresent(currentCacheReadTokens, forKey: .currentCacheReadTokens)
        try c.encodeIfPresent(currentInputTokens, forKey: .currentInputTokens)
        try c.encodeIfPresent(currentContextTokens, forKey: .currentContextTokens)
    }

    enum CodingKeys: String, CodingKey {
        case _id, workerId, sessionLabel, status, capabilities
        case lastHeartbeat, currentEventId, registeredAt, currentTask, assignedAt
        case currentEventTokens, currentSlug, currentCacheReadTokens, currentInputTokens
        case currentContextTokens
    }
}

private struct PromptCacheStatsItem: Encodable {
    let promptKey: String
    let eventType: String
    let promptHash: String
    let totalInputTokens: Int64
    let totalCacheReadTokens: Int64
    let sampleCount: Int64
    let lastSeenAt: Int64
    let hitRate: Double?
    let sessionLabel: String?
    let cwdBasename: String?
}

// MARK: - Helpers

/// SQL predicate matching a worker-pool slot, for use in a `workers` query.
///
/// The pool is exactly the `sona-worker-N` slots. Other things legitimately
/// hold a `workers` row — sidecars register one so their token usage is
/// visible to the context monitor — but they are long-lived sessions that
/// receive work only by explicit assignment, and handing them generic pending
/// events would pull them off the job they exist to do.
///
/// Shared rather than inlined because the three selectors that pick "an idle
/// worker" (`MCPEventPusher.assignPendingToIdleWorkers`,
/// `SonataChannelServer.findIdleWorker`, `TaskDispatcher`'s concurrency count)
/// each had their own version of this rule and only one of them was right —
/// two would happily have dispatched arbitrary tasks into a sidecar. One
/// constant so the next thing that registers a `workers` row can't reopen the
/// same gap.
let poolSlotSQLPredicate = "sessionLabel GLOB 'sona-worker-*'"

/// Sweep workers whose lastHeartbeat is older than 30s ago — mark them
/// `offline` (an ALERT), delete draining ones. Bridge heartbeats every 15s,
/// so 30s gives a 2x margin while clearing ghost rows quickly when a session
/// dies.
///
/// This sweep used to ALSO fail the assigned event and retry-or-fail the
/// backing task in the same pass. That was tight and destructive: a legit
/// long tool call over the 30s window would flip the task to pending, the
/// dispatcher would race the returning worker's next claim, and two workers
/// would end up on the same task_id (wiki-compilation dupe 2026-07-07).
///
/// The sweep is now ALERT-only. The escalation loop in HealthMonitor
/// (`escalateOfflineWorkers`) reads the `offline` signal, DMs the worker as
/// a second-signal liveness check, and reaps (cancel event + retry task +
/// cycle process) only after a grace period without recovery. Fix #2 in
/// worker_heartbeat lets a heartbeat un-stick `offline` back to `busy`/`idle`,
/// so a false-positive sweep flip self-heals in the normal case.
private func sweepStaleWorkersForActions(in db: Database) throws {
    let cutoff = nowMs() - 30_000

    // Restart-recovery v0: exclude `recovering` so freshly-respawned workers
    // get their 30s grace window before the sweeper marks them offline
    // (sonata-restart-recovery-v0 §4 / §7). The recovery path stamps
    // lastHeartbeat=now when it flips status='recovering', so this guard is
    // a redundant belt-and-suspenders.
    try db.execute(sql: """
        UPDATE workers SET status = 'offline'
        WHERE lastHeartbeat < ? AND status NOT IN ('offline', 'draining', 'recovering')
    """, arguments: [cutoff])

    // Draining workers were intentionally retired by WorkerManager — surfacing
    // them as 'offline' makes the supervisor try to fix a worker that is
    // supposed to be going away. Drop them outright once they stop
    // heartbeating.
    try db.execute(sql: """
        DELETE FROM workers
        WHERE lastHeartbeat < ? AND status = 'draining'
    """, arguments: [cutoff])

    // Note: hard deletion of long-offline rows is intentionally left to explicit
    // worker_purge only. Auto-deleting here caused live sessions to lose their DB
    // registration while still running, making the pool appear empty even when
    // workers were alive.
}

let workerActions: [SonataAction] = [

    // POST /api/worker/register — upsert worker by workerId, sweep stale
    SonataAction(
        name: "worker_register",
        description: "Register a worker (upsert by workerId) and sweep stale workers.",
        group: "/api/worker",
        path: "/register",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier"),
            ActionParam("sessionLabel", .string, required: true, description: "Human-readable session label"),
            ActionParam("capabilities", .stringArray, description: "Capabilities (comma-separated or array)"),
            ActionParam("sessionId", .string, description: "Claude session UUID for cycling/resume"),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            let sessionLabel = ctx.params.string("sessionLabel") ?? ""
            let sessionId = ctx.params.string("sessionId")

            let now = nowMs()
            let capsJSON = encodeTags(ctx.params.stringArray("capabilities") ?? [])

            do {
                try await ctx.dbPool.write { db in
                    // sessionLabel is the "slot"; workerId is the running instance.
                    // When a fresh process registers, drop any predecessors that occupied the same slot.
                    if !sessionLabel.isEmpty {
                        // Release any in-flight events held by predecessors before
                        // deleting their rows. Otherwise the events sit `assigned`
                        // forever pointing at a workerId nothing can sweep.
                        try db.execute(
                            sql: """
                                UPDATE workerEvents SET assignedTo = NULL, status = 'pending'
                                WHERE status = 'assigned' AND assignedTo IN (
                                    SELECT workerId FROM workers
                                    WHERE sessionLabel = ? AND workerId != ?
                                )
                            """,
                            arguments: [sessionLabel, workerId]
                        )
                        try db.execute(
                            sql: "DELETE FROM workers WHERE sessionLabel = ? AND workerId != ?",
                            arguments: [sessionLabel, workerId]
                        )
                    }
                    // Status is derived from currentEventId on register too —
                    // a registering worker with prior work pending (restart-recovery
                    // case) must come up 'busy', not 'idle', or the UI shows the
                    // wrong state until the first heartbeat fixes it.
                    try db.execute(
                        sql: """
                        INSERT INTO workers (id, workerId, sessionLabel, status, capabilities, lastHeartbeat, registeredAt, sessionId)
                        VALUES (?, ?, ?, 'idle', ?, ?, ?, ?)
                        ON CONFLICT(workerId) DO UPDATE SET
                            sessionLabel = excluded.sessionLabel,
                            capabilities = excluded.capabilities,
                            lastHeartbeat = excluded.lastHeartbeat,
                            sessionId = excluded.sessionId,
                            status = CASE
                                WHEN status = 'draining' THEN status
                                WHEN currentEventId IS NOT NULL AND currentEventId != '' THEN 'busy'
                                ELSE 'idle'
                            END
                        """,
                        arguments: [newUUID(), workerId, sessionLabel, capsJSON, now, now, sessionId]
                    )
                    try sweepStaleWorkersForActions(in: db)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/worker/heartbeat — update lastHeartbeat, sweep stale
    SonataAction(
        name: "worker_heartbeat",
        description: "Heartbeat a worker; update lastHeartbeat, live-monitoring fields, and sweep stale workers.",
        group: "/api/worker",
        path: "/heartbeat",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier"),
            ActionParam("lastProgressAt", .integer, description: "Last progress timestamp (epoch ms)"),
            ActionParam("currentEventTokens", .integer, description: "Cumulative tokens for in-flight event"),
            ActionParam("currentSlug", .string, description: "Coarse 'what is it doing' label (event type in v0)"),
            ActionParam("currentCacheReadTokens", .integer, description: "Cumulative cache_read_input_tokens for in-flight event"),
            ActionParam("currentInputTokens", .integer, description: "Cumulative input-side tokens for in-flight event"),
            ActionParam("currentContextTokens", .integer, description: "Last assistant turn's input+cacheCreate+cacheRead — how full the session's context window is right now (session-scoped, sent between events too)"),
            ActionParam("promptHash", .string, description: "8-char sha256 prefix of the event's prompt prefix"),
            ActionParam("sessionLabel", .string, description: "Human-readable worker-pool label (display for prompt cache panel)"),
            ActionParam("cwdBasename", .string, description: "Last path segment of worker cwd (display suffix)"),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            let lastProgressAt = ctx.params.int("lastProgressAt").map { Int64($0) }
            let currentEventTokens = ctx.params.int("currentEventTokens").map { Int64($0) }
            let currentSlug = ctx.params.string("currentSlug")
            let currentCacheReadTokens = ctx.params.int("currentCacheReadTokens").map { Int64($0) }
            let currentInputTokens = ctx.params.int("currentInputTokens").map { Int64($0) }
            let currentContextTokens = ctx.params.int("currentContextTokens").map { Int64($0) }
            let promptHash = ctx.params.string("promptHash")
            let sessionLabel = ctx.params.string("sessionLabel")
            let cwdBasename = ctx.params.string("cwdBasename")

            let now = nowMs()
            do {
                let changed = try await ctx.dbPool.write { db -> Int in
                    // Status is derived on every heartbeat: any worker with a
                    // currentEventId is BUSY, any without one is IDLE. Draining
                    // stays sticky (explicit lifecycle exit). Offline is NOT
                    // sticky — if a heartbeat arrives, the worker is alive by
                    // definition; a stale sweep flip must self-heal rather than
                    // sitting until Evan manually DMs the worker to fix itself.
                    // The escalation loop in HealthMonitor still catches genuine
                    // deaths via missing-heartbeat, so this only recovers
                    // false-positive offline flags.
                    try db.execute(
                        sql: """
                        UPDATE workers SET
                            lastHeartbeat = ?,
                            -- lastProgressAt precedence:
                            --   (1) caller-supplied wins when present (future-proof —
                            --       lets a daemon send a more-accurate stamp than the
                            --       heartbeat clock);
                            --   (2) if the worker holds an in-flight event, the
                            --       heartbeat itself IS progress (the daemon
                            --       heartbeats over HTTP independent of SSE state, so
                            --       this closes the "SSE briefly dropped mid-tool-call
                            --       → reclaimStrandedEvents false-positive" window);
                            --   (3) otherwise preserve whatever's there.
                            lastProgressAt = CASE
                                WHEN ? IS NOT NULL THEN ?
                                WHEN currentEventId IS NOT NULL AND currentEventId != '' THEN ?
                                ELSE lastProgressAt
                            END,
                            currentEventTokens = COALESCE(?, currentEventTokens),
                            currentSlug = COALESCE(?, currentSlug),
                            currentCacheReadTokens = COALESCE(?, currentCacheReadTokens),
                            currentInputTokens = COALESCE(?, currentInputTokens),
                            -- Session-scoped, unlike its neighbours: no event
                            -- completion clears it, because a session's context
                            -- doesn't empty when its event does.
                            currentContextTokens = COALESCE(?, currentContextTokens),
                            currentPromptHash = COALESCE(?, currentPromptHash),
                            currentSessionLabel = COALESCE(?, currentSessionLabel),
                            currentCwdBasename = COALESCE(?, currentCwdBasename),
                            status = CASE
                                WHEN status = 'draining' THEN status
                                WHEN currentEventId IS NOT NULL AND currentEventId != '' THEN 'busy'
                                ELSE 'idle'
                            END
                        WHERE workerId = ?
                        """,
                        arguments: [now,
                                    lastProgressAt, lastProgressAt, now,
                                    currentEventTokens, currentSlug,
                                    currentCacheReadTokens, currentInputTokens,
                                    currentContextTokens,
                                    promptHash, sessionLabel, cwdBasename, workerId]
                    )
                    let count = db.changesCount
                    try sweepStaleWorkersForActions(in: db)
                    return count
                }
                // Worker row is gone (purged by supervisor or supplanted by predecessor-cleanup).
                // Tell the bridge to re-register instead of heartbeating into the void forever.
                guard changed > 0 else {
                    throw ActionError.custom("unknown worker — re-register", .gone)
                }
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/worker/unregister?workerId= — delete worker
    SonataAction(
        name: "worker_unregister",
        description: "Unregister a worker by workerId.",
        group: "/api/worker",
        path: "/unregister",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier", source: .query),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            do {
                try await ctx.dbPool.write { db in
                    // Release any in-flight events before the row goes away.
                    try db.execute(
                        sql: """
                            UPDATE workerEvents SET assignedTo = NULL, status = 'pending'
                            WHERE assignedTo = ? AND status = 'assigned'
                        """,
                        arguments: [workerId]
                    )
                    try db.execute(sql: "DELETE FROM workers WHERE workerId = ?", arguments: [workerId])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/worker/purge — delete stale workers, unassign their events
    SonataAction(
        name: "worker_purge",
        description: "Purge workers whose lastHeartbeat is older than 60s; unassign their events.",
        group: "/api/worker",
        path: "/purge",
        method: .post,
        params: [],
        handler: { ctx in
            let cutoff = nowMs() - 60_000
            do {
                let purged = try await ctx.dbPool.write { db -> Int in
                    let staleRows = try Row.fetchAll(db,
                        sql: "SELECT workerId FROM workers WHERE lastHeartbeat < ?",
                        arguments: [cutoff]
                    )
                    let staleIds = staleRows.map { $0["workerId"] as String }

                    for wid in staleIds {
                        try db.execute(
                            sql: """
                            UPDATE workerEvents SET assignedTo = NULL, status = 'pending'
                            WHERE assignedTo = ? AND status = 'assigned'
                            """,
                            arguments: [wid]
                        )
                    }

                    try db.execute(
                        sql: "DELETE FROM workers WHERE lastHeartbeat < ?",
                        arguments: [cutoff]
                    )
                    return staleIds.count
                }
                return PurgeResponse(purged: purged)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/worker/pool/reconcile — adopt DB workers the UI lost.
    //
    // Repairs the "DB has a worker the UI doesn't" drift class. Queries
    // the workers table for pool slots (sessionLabel like sona-worker-*),
    // then hands the list to WorkerManager.adoptOrphans on the MainActor.
    // Anything whose claude process is still alive on the host gets a
    // fresh local Worker instance appended so the UI sees it again.
    // Anything without a live process is left alone — the pool
    // maintainer's normal path handles those.
    //
    // Supervisor / operator flow: when the UI shows fewer workers than
    // `worker_list` reports, call this once. Idempotent — Workers already
    // in the local array are skipped.
    SonataAction(
        name: "worker_pool_reconcile",
        description: "Adopt DB workers whose claude process is alive but whose local Worker instance was lost from the SwiftUI array (UI shows fewer rows than worker_list). Returns the workerIds actually adopted.",
        group: "/api/worker",
        path: "/pool/reconcile",
        method: .post,
        params: [],
        handler: { ctx in
            // sessionId is nullable in the workers table (schema
            // predates the field being populated at register time), and
            // GRDB's Decodable path throws on a NULL for a non-optional
            // String — silently swallowing the whole fetchAll under a
            // `try?`. Optional decode + empty-string fallback keeps the
            // reconciliation working on rows that lack a sessionId, at
            // the cost of a slightly less useful --resume story for
            // adopted Workers (the recovery init only uses sessionId to
            // pass through to Worker.sessionId, which the reconcile
            // path doesn't hand to startProcess anyway).
            struct Row: Decodable, FetchableRecord {
                let workerId: String
                let sessionLabel: String
                let sessionId: String?
            }
            let rows: [Row] = (try? await ctx.dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT workerId, sessionLabel, sessionId FROM workers
                    WHERE sessionLabel GLOB 'sona-worker-*'
                """)
            }) ?? []
            let candidates = rows.map { ($0.workerId, $0.sessionLabel, $0.sessionId ?? "") }
            let adopted = await MainActor.run {
                WorkerManager.shared.adoptOrphans(candidates: candidates)
            }
            return ReconcileResponse(adopted: adopted, considered: candidates.count)
        }
    ),

    // POST /api/worker/spawn — top the pool up to defaultWorkerCount.
    // Gives the supervisor an MCP path to self-heal under-capacity pool
    // states. WorkerManager.maintainPoolSize() is the same routine the
    // health-poll loop runs; we just expose it as a tool. Fills missing
    // slot indices only — never grows the pool beyond defaultWorkerCount.
    //
    // 2026-05-18 incident: supervisor purged a zombie, auto-spawn brought
    // up one replacement, then pool stayed at 1/2 because the auto-spawn
    // path didn't refire. Without this tool the supervisor's only
    // recourse was to page Evan; #3 separately tracks fixing the
    // auto-spawn flake itself.
    SonataAction(
        name: "worker_spawn",
        description: "Top the worker pool up to defaultWorkerCount. Returns labels of slots that were spawned; empty array if the pool was already full.",
        group: "/api/worker",
        path: "/spawn",
        method: .post,
        params: [],
        handler: { _ in
            let spawned = await MainActor.run {
                WorkerManager.shared.maintainPoolSize()
            }
            return SpawnResponse(spawned: spawned)
        }
    ),

    // GET /api/worker/list — all workers with current task info
    SonataAction(
        name: "worker_list",
        description: "List all workers with their current task, heartbeat, and status.",
        group: "/api/worker",
        path: "/list",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows: [Row] = try ctx.dbPool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT w.*,
                            COALESCE(
                                json_extract(e.payload, '$.title'),
                                t.title
                            ) as currentTask,
                            e.assignedAt as eventAssignedAt
                        FROM workers w
                        LEFT JOIN workerEvents e ON w.currentEventId = e.id
                        LEFT JOIN tasks t ON json_extract(e.payload, '$.task_id') = t.id
                        ORDER BY w.lastHeartbeat DESC
                    """)
                }
                return rows.map { row -> WorkerListItem in
                    WorkerListItem(
                        _id: row["id"] as? String ?? "",
                        workerId: row["workerId"] as? String ?? "",
                        sessionLabel: row["sessionLabel"] as? String ?? "",
                        status: row["status"] as? String ?? "offline",
                        capabilities: row["capabilities"] as? String ?? "[]",
                        lastHeartbeat: row["lastHeartbeat"] as? Int64 ?? 0,
                        currentEventId: row["currentEventId"] as? String ?? "",
                        registeredAt: row["registeredAt"] as? Int64 ?? 0,
                        currentTask: row["currentTask"] as? String,
                        assignedAt: row["eventAssignedAt"] as? Int64,
                        currentEventTokens: row["currentEventTokens"] as? Int64,
                        currentSlug: row["currentSlug"] as? String,
                        currentCacheReadTokens: row["currentCacheReadTokens"] as? Int64,
                        currentInputTokens: row["currentInputTokens"] as? Int64,
                        currentContextTokens: row["currentContextTokens"] as? Int64
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/worker/drain — mark worker as draining (cycling)
    SonataAction(
        name: "worker_drain",
        description: "Mark a worker as draining so it won't receive new events.",
        group: "/api/worker",
        path: "/drain",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier", source: .query),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            do {
                try await ctx.dbPool.write { db in
                    // Event-aware drain. A worker can be racily re-assigned a fresh
                    // event in the window between going idle (post-complete) and this
                    // drain landing — the complete→idle→EventPusher(1s tick)→drain race
                    // behind the 4-task auto-cycle. A blind flip to 'draining' would
                    // strand that event on a worker we are about to SIGTERM (its SSE
                    // push most likely went to the dying session and was never seen).
                    // So, in one transaction: re-enqueue any still-'assigned'
                    // currentEvent back to 'pending' for another worker, clear it, then
                    // set 'draining'. Draining must never orphan an event.
                    if let evtId = try String.fetchOne(db, sql:
                            "SELECT currentEventId FROM workers WHERE workerId = ?",
                            arguments: [workerId]),
                       !evtId.isEmpty {
                        try db.execute(sql: """
                            UPDATE workerEvents SET assignedTo = NULL, status = 'pending'
                            WHERE id = ? AND status = 'assigned'
                        """, arguments: [evtId])
                    }
                    try db.execute(sql: """
                        UPDATE workers SET status = 'draining', currentEventId = NULL
                        WHERE workerId = ?
                    """, arguments: [workerId])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/worker/undrain — un-drain a worker (cycle abort)
    SonataAction(
        name: "worker_undrain",
        description: "Un-drain a worker, setting it back to idle.",
        group: "/api/worker",
        path: "/undrain",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier", source: .query),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "UPDATE workers SET status = 'idle' WHERE workerId = ?",
                                   arguments: [workerId])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/prompt_cache_stats — aggregated cache hit-rate per prompt template
    SonataAction(
        name: "prompt_cache_stats",
        description: "List per-prompt-template cache hit-rate aggregates, highest-sample first.",
        group: "/api",
        path: "/prompt_cache_stats",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows: [Row] = try ctx.dbPool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT promptKey, eventType, promptHash,
                               totalInputTokens, totalCacheReadTokens,
                               sampleCount, lastSeenAt,
                               sessionLabel, cwdBasename
                        FROM promptCacheStats
                        ORDER BY sampleCount DESC, lastSeenAt DESC
                    """)
                }
                return rows.map { row -> PromptCacheStatsItem in
                    let input = row["totalInputTokens"] as? Int64 ?? 0
                    let cacheRead = row["totalCacheReadTokens"] as? Int64 ?? 0
                    let hitRate: Double? = input > 0 ? Double(cacheRead) / Double(input) : nil
                    return PromptCacheStatsItem(
                        promptKey: row["promptKey"] as? String ?? "",
                        eventType: row["eventType"] as? String ?? "",
                        promptHash: row["promptHash"] as? String ?? "",
                        totalInputTokens: input,
                        totalCacheReadTokens: cacheRead,
                        sampleCount: row["sampleCount"] as? Int64 ?? 0,
                        lastSeenAt: row["lastSeenAt"] as? Int64 ?? 0,
                        hitRate: hitRate,
                        sessionLabel: row["sessionLabel"] as? String,
                        cwdBasename: row["cwdBasename"] as? String
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/worker/set_status — supervisor repair: directly set worker.status
    SonataAction(
        name: "worker_set_status",
        description: "Directly set a worker's status field (supervisor repair tool for mismatched state).",
        group: "/api/worker",
        path: "/set_status",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier"),
            ActionParam("status", .string, required: true, description: "Target status: idle, busy, draining, offline"),
            ActionParam("clearCurrentEvent", .boolean, description: "If true, also NULL out currentEventId and live-monitoring fields"),
            ActionParam("expectedEventId", .string, description: "Required when clearCurrentEvent is true: the event id the caller believes the worker holds (worker_inspect reports it). The clear no-ops (success:false) if currentEventId has moved on."),
            ActionParam("force", .boolean, description: "Clear currentEventId without an expectedEventId match. Logged at warning level — genuine mismatched-state repair only."),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            let status = try ctx.params.require("status")
            let clearCurrent = ctx.params.bool("clearCurrentEvent") ?? false
            let expectedEventId = ctx.params.string("expectedEventId")
            let force = ctx.params.bool("force") ?? false
            let allowed: Set<String> = ["idle", "busy", "draining", "offline"]
            guard allowed.contains(status) else {
                throw ActionError.invalidParam("status", "must be one of: idle, busy, draining, offline")
            }
            // 2026-07-20: a blind clear can eat a task the dispatcher landed
            // microseconds ago. Worker 8368256472 called complete_event, the
            // dispatcher assigned BKSK 1.3s later, and the worker's habitual
            // clearCurrentEvent nulled an event it had never seen — closing it
            // with the task still `pending`, whose day-scoped idempotency key
            // then blocked redispatch until midnight and starved five tasks
            // chained behind it. Requiring expectedEventId makes the caller
            // observe the state it is about to mutate. Absent is REJECTED
            // rather than defaulted to the old behavior: an optional guard that
            // falls back to "clear whatever's there" protects nobody, because
            // every existing caller keeps sailing past it.
            if clearCurrent && expectedEventId == nil && !force {
                throw ActionError.invalidParam(
                    "expectedEventId",
                    "required when clearCurrentEvent is true — pass the event id you believe the worker holds (worker_inspect reports it). If you do not know which event you hold, you should not be clearing it: after complete_event or fail_event the slot is already released, so this call is unnecessary."
                )
            }
            do {
                let outcome = try await ctx.dbPool.write { db -> (cleared: Bool, held: String?) in
                    if clearCurrent {
                        // Capture the event this worker points at BEFORE nulling
                        // it, then close that dangling workerEvent too. Otherwise
                        // the worker frees but its event stays `assigned` forever
                        // — a leak that (for sonar_dm) shadows the dm_reply
                        // auto-complete and re-strands the next DM (2026-07-17).
                        // Only close an event still `assigned` to THIS worker.
                        let heldEventId = try String.fetchOne(db,
                            sql: "SELECT currentEventId FROM workers WHERE workerId = ?",
                            arguments: [workerId])
                        let held = (heldEventId?.isEmpty == false) ? heldEventId : nil

                        // Compare-and-swap. Refuse when the slot holds something
                        // other than what the caller expected — including when it
                        // is already empty, which means someone else got here
                        // first and whatever we would clear next is not ours.
                        guard clearCurrentEventShouldProceed(
                            held: held, expected: expectedEventId, force: force
                        ) else {
                            return (cleared: false, held: held)
                        }

                        try db.execute(sql: """
                            UPDATE workers SET
                                status = ?,
                                currentEventId = NULL,
                                currentEventTokens = NULL,
                                currentSlug = NULL,
                                currentCacheReadTokens = NULL,
                                currentInputTokens = NULL,
                                currentPromptHash = NULL,
                                currentSessionLabel = NULL,
                                currentCwdBasename = NULL
                            WHERE workerId = ?
                        """, arguments: [status, workerId])
                        if let held {
                            try db.execute(sql: """
                                UPDATE workerEvents SET status = 'completed', completedAt = ?,
                                    result = 'closed via worker_set_status(clearCurrentEvent)',
                                    idempotencyKey = NULL
                                WHERE id = ? AND status = 'assigned' AND assignedTo = ?
                            """, arguments: [nowMs(), held, workerId])
                        }
                        return (cleared: true, held: held)
                    } else {
                        try db.execute(
                            sql: "UPDATE workers SET status = ? WHERE workerId = ?",
                            arguments: [status, workerId]
                        )
                        return (cleared: true, held: nil)
                    }
                }
                if clearCurrent && !outcome.cleared {
                    // Visible refusal, not a silent no-op. A caller that believes
                    // it released a genuinely stuck event and walks away is the
                    // same bug this guard exists to prevent, wearing a different
                    // hat — so report what the slot actually holds.
                    workerLogger.warning(
                        "worker_set_status: refusing clearCurrentEvent on \(workerId) — expected \(expectedEventId ?? "nil"), holds \(outcome.held ?? "nothing")"
                    )
                    return ClearRefusedResponse(currentEventId: outcome.held)
                }
                if clearCurrent && force && expectedEventId == nil {
                    workerLogger.warning(
                        "worker_set_status: FORCED unguarded clearCurrentEvent on \(workerId) — closed \(outcome.held ?? "nothing")"
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/worker/status — summary
    SonataAction(
        name: "worker_status",
        description: "Summary worker status: online, busy, pending event counts.",
        group: "/api/worker",
        path: "/status",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                // Match the sweep cutoff so a worker the sweeper just marked
                // offline doesn't still register as "online" here.
                let cutoff = nowMs() - 30_000
                return try await ctx.dbPool.read { db -> WorkerStatusResponse in
                    let online = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM workers WHERE lastHeartbeat >= ?",
                        arguments: [cutoff]
                    ) ?? 0
                    let busy = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM workers WHERE status = 'busy' AND lastHeartbeat >= ?",
                        arguments: [cutoff]
                    ) ?? 0
                    let pending = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM workerEvents WHERE status = 'pending'"
                    ) ?? 0
                    return WorkerStatusResponse(online: online, busy: busy, pendingEvents: pending)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]

// MARK: - Inspector Action

let inspectorAction: [SonataAction] = [
    SonataAction(
        name: "worker_inspect",
        description: "Open an inspector window to resume a past worker session.",
        group: "/api/worker",
        path: "/inspect",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Claude session UUID to resume"),
            ActionParam("title", .string, description: "Task title for window label"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            let title = ctx.params.string("title") ?? "Inspector"
            DispatchQueue.main.async {
                let controller = InspectorWindowController(sessionId: sessionId, taskTitle: title)
                controller.open()
                InspectorWindowStore.shared.add(controller)
            }
            return SuccessResponse()
        }
    ),
]

// MARK: - Worker Event Actions (claim, complete, fail, recent, enqueue)

private func eventToResponse(_ row: WorkerEventRow) -> WorkerEventResponse {
    WorkerEventResponse(
        _id: row.id,
        type: row.type,
        payload: row.payload,
        priority: row.priority,
        assignedTo: row.assignedTo,
        status: row.status,
        result: row.result,
        createdAt: row.createdAt,
        assignedAt: row.assignedAt,
        completedAt: row.completedAt,
        sessionId: row.sessionId
    )
}

private struct ClaimedFalseResponse: Encodable {
    let claimed = false
}

let workerEventActions: [SonataAction] = [

    // POST /api/worker/events/enqueue — create a worker event
    SonataAction(
        name: "worker_event_enqueue",
        description: "Create a pending worker event.",
        group: "/api/worker/events",
        path: "/enqueue",
        method: .post,
        params: [
            ActionParam("type", .string, required: true, description: "Event type (email, task, alert)"),
            ActionParam("payload", .string, required: true, description: "JSON payload"),
            ActionParam("priority", .integer, description: "Priority 1-10 (default 5)"),
        ],
        handler: { ctx in
            let type = try ctx.params.require("type")
            let payload = try ctx.params.require("payload")
            let priority = ctx.params.int("priority") ?? 5
            let now = nowMs()
            let id = newUUID()
            let idemKey = WorkerEventIdempotency.key(type: type, payloadJSON: payload)

            // Sidecar routing seam. A sidecar owns a set of event types
            // outright, so an event of one of those types is pre-assigned to
            // its live session instead of landing `pending` for the pool.
            //
            // This is the only enqueue site that needs the lookup.
            // `MCPEventPusher.pushPendingWorkerEvents` routes purely on
            // `assignedTo`, so writing the right value here is sufficient —
            // and it has to happen here rather than at push time, because
            // `assignPendingToIdleWorkers` would otherwise hand the event to a
            // pool slot first (sidecars are excluded from that selector by
            // `poolSlotSQLPredicate`, but the event isn't).
            //
            // Nil covers three cases that all mean "route normally": no
            // sidecar owns this type, the owner has never spawned, or it is
            // mid-rotation with its key withdrawn. Deliberately additive —
            // when it's nil the INSERT below is byte-for-byte the original.
            //
            // Note the asymmetry with the pool path: no `workers.status =
            // 'busy'` CAS is taken here. A sidecar is a long-lived dispatcher
            // that returns immediately, not a slot that gets consumed, and
            // claiming it busy would make the context monitor's drain check
            // read it as permanently occupied.
            let sidecarAssignee = SidecarRegistry.shared.assignee(forEventType: type)

            do {
                try await ctx.dbPool.write { db in
                    if let sidecarAssignee {
                        try db.execute(sql: """
                            INSERT INTO workerEvents (id, type, payload, priority, assignedTo, status, createdAt, assignedAt, idempotencyKey)
                            VALUES (?, ?, ?, ?, ?, 'assigned', ?, ?, ?)
                            ON CONFLICT(idempotencyKey) DO NOTHING
                        """, arguments: [id, type, payload, priority, sidecarAssignee, now, now, idemKey])
                    } else {
                        try db.execute(sql: """
                            INSERT INTO workerEvents (id, type, payload, priority, status, createdAt, idempotencyKey)
                            VALUES (?, ?, ?, ?, 'pending', ?, ?)
                            ON CONFLICT(idempotencyKey) DO NOTHING
                        """, arguments: [id, type, payload, priority, now, idemKey])
                    }
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // POST /api/worker/events/claim — claim next pending event for a worker
    SonataAction(
        name: "worker_event_claim",
        description: "Claim the next pending worker event. Returns the event or {claimed:false}.",
        group: "/api/worker/events",
        path: "/claim",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier"),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            let now = nowMs()
            do {
                let event = try await ctx.dbPool.write { db -> WorkerEventRow? in
                    // Don't let a busy or draining worker claim events.
                    // Also refuse workers whose sessionLabel doesn't match the
                    // expected shape — bridge launched outside SonataApp produced
                    // sessionLabel="worker" stragglers (2026-04-28 incident).
                    let workerRow = try Row.fetchOne(db, sql: """
                        SELECT currentEventId, status, sessionLabel FROM workers WHERE workerId = ?
                    """, arguments: [workerId])
                    if let workerRow {
                        let status = workerRow["status"] as? String ?? ""
                        let currentEvent = workerRow["currentEventId"] as? String
                        if currentEvent != nil || status == "draining" { return nil }
                        let label = workerRow["sessionLabel"] as? String ?? ""
                        let isValidLabel = label == "supervisor"
                            || label.range(of: #"^sona-worker-\d+$"#, options: .regularExpression) != nil
                        if !isValidLabel { return nil }
                    }

                    // Find event: pre-assigned to this worker first, then any pending
                    guard let row = try WorkerEventRow.fetchOne(db, sql: """
                        SELECT * FROM workerEvents
                        WHERE (status = 'assigned' AND assignedTo = ?) OR status = 'pending'
                        ORDER BY
                            CASE WHEN status = 'assigned' AND assignedTo = ? THEN 0 ELSE 1 END,
                            priority DESC, createdAt ASC
                        LIMIT 1
                    """, arguments: [workerId, workerId]) else {
                        return nil
                    }

                    // Task-level dupe guard for FRESH pending picks. If another
                    // event for the same task_id is already assigned (to any
                    // worker) or pending, THIS event is a stale duplicate — a
                    // sweep or reclaim re-enqueue that raced past the dispatcher-
                    // side guard. Cancel it and refuse to claim. Skip the check
                    // when we're resuming our OWN pre-assigned event (that IS
                    // the canonical event for this worker).
                    let isResumingOwnAssigned = row.status == "assigned" && row.assignedTo == workerId
                    if !isResumingOwnAssigned,
                       let payloadData = row.payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                       let claimTaskId = json["task_id"] as? String, !claimTaskId.isEmpty {
                        // assignedTo IS NULL/'' clause: defense in depth against a
                        // race where an event was reset to 'pending' but its
                        // assignedTo lingered on the row — that row is still
                        // owned by someone. Without this clause we'd read it
                        // as an "active other" and cancel our own fresh pick,
                        // even though the other event is stranded.
                        let otherActive = try Int.fetchOne(db, sql: """
                            SELECT COUNT(*) FROM workerEvents
                            WHERE json_extract(payload, '$.task_id') = ?
                              AND id != ?
                              AND (
                                status = 'assigned'
                                OR (status = 'pending' AND (assignedTo IS NULL OR assignedTo = ''))
                              )
                        """, arguments: [claimTaskId, row.id]) ?? 0
                        if otherActive > 0 {
                            try db.execute(sql: """
                                UPDATE workerEvents
                                SET status = 'cancelled', completedAt = ?, result = ?
                                WHERE id = ? AND status = 'pending'
                            """, arguments: [now, "cancelled by task-level dupe guard: another event for task \(claimTaskId) is already active", row.id])
                            return nil
                        }
                    }

                    // Look up worker's sessionId for cycling/resume
                    let workerSessionId = try String.fetchOne(db, sql: """
                        SELECT sessionId FROM workers WHERE workerId = ?
                    """, arguments: [workerId])

                    // Assign it (copy sessionId from worker to event).
                    // Explicit SQL CAS: only pick up the row if it's still
                    // pending AND unassigned. GRDB's write serializer already
                    // gives us statement-atomicity, but this converts the
                    // guarantee from "no concurrent writers thanks to the
                    // mutex" to "the UPDATE itself refuses the row if the
                    // premise no longer holds." Skips the pre-assigned branch:
                    // when we're resuming our OWN assigned event, the row
                    // already has assignedTo=workerId and status='assigned',
                    // so the guard would (correctly) refuse — no update
                    // needed, the row is already in the state we want.
                    if !isResumingOwnAssigned {
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET assignedTo = ?, status = 'assigned', assignedAt = ?, sessionId = ?
                            WHERE id = ?
                              AND status = 'pending'
                              AND (assignedTo IS NULL OR assignedTo = '')
                        """, arguments: [workerId, now, workerSessionId, row.id])
                        guard db.changesCount == 1 else { return nil }
                    }

                    // Mark worker busy. Bump lastHeartbeat to `now` at claim time so
                    // that lastHeartbeat >= assignedAt; otherwise the supervisor sees a
                    // worker whose assignedAt is fresh but heartbeat is stale and can't
                    // tell "just claimed" from "dead session." The bridge will resume
                    // its 15s heartbeat shortly after; this is the seed.
                    try db.execute(sql: """
                        UPDATE workers SET status = 'busy', currentEventId = ?, lastHeartbeat = ?
                        WHERE workerId = ?
                    """, arguments: [row.id, now, workerId])

                    return try WorkerEventRow.fetchOne(db,
                        sql: "SELECT * FROM workerEvents WHERE id = ?",
                        arguments: [row.id])
                }
                if let event {
                    return eventToResponse(event)
                } else {
                    return ClaimedFalseResponse()
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/worker/events/complete — mark event completed, free worker
    SonataAction(
        name: "worker_event_complete",
        description: "Mark a worker event as completed and set worker back to idle.",
        group: "/api/worker/events",
        path: "/complete",
        method: .post,
        params: [
            ActionParam("eventId", .string, required: true, description: "Event ID"),
            ActionParam("workerId", .string, description: "Worker ID (optional)"),
            ActionParam("result", .string, description: "Result summary"),
        ],
        handler: { ctx in
            let eventId = try ctx.params.require("eventId")
            let resultText = ctx.params.string("result")
            let now = nowMs()
            // `rotateSidecar` rides out of the transaction alongside the freed
            // worker id: the rotation it triggers must happen *after* the
            // commit, but whether to rotate at all can only be decided inside,
            // where the owner-guard has already ruled the completion genuine.
            let completion: (workerId: String?, rotateSidecar: String?)
            do {
                completion = try await ctx.dbPool.write { db -> (workerId: String?, rotateSidecar: String?) in
                    let row = try WorkerEventRow.fetchOne(db,
                        sql: "SELECT * FROM workerEvents WHERE id = ?",
                        arguments: [eventId])

                    // Pull totalTokens + model attribution off the worker row before
                    // we clear it. Model resolves from the payload's `model` field
                    // when present (the dispatcher propagates tasks.model into the
                    // payload), else falls back to Opus — matches the rest of the
                    // system's default for dispatched task work.
                    var attributedTokens: Int64?
                    var attributedModel: String?
                    if let workerId = row?.assignedTo {
                        let tokRow = try Row.fetchOne(db, sql: """
                            SELECT currentEventTokens FROM workers WHERE workerId = ?
                        """, arguments: [workerId])
                        attributedTokens = tokRow?["currentEventTokens"] as? Int64
                    }
                    if let payload = row?.payload,
                       let payloadData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                       let m = json["model"] as? String, !m.isEmpty {
                        attributedModel = m
                    }
                    if attributedModel == nil { attributedModel = ModelPricing.defaultModel }

                    // Owner-guard: only terminate the event if it is still
                    // 'assigned' to the CALLER. A stale completion from a zombie
                    // session whose event was already reaped or reassigned must
                    // NOT complete the (possibly re-dispatched, now-active) task
                    // or reset the worker that currently owns the event. Legacy
                    // callers without a workerId fall back to the status guard.
                    let callerWorkerId = ctx.params.string("workerId")
                    if let callerWorkerId, !callerWorkerId.isEmpty {
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET status = 'completed', result = ?, completedAt = ?,
                                totalTokens = COALESCE(?, totalTokens), model = COALESCE(?, model)
                            WHERE id = ? AND status = 'assigned' AND assignedTo = ?
                        """, arguments: [resultText, now, attributedTokens, attributedModel, eventId, callerWorkerId])
                    } else {
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET status = 'completed', result = ?, completedAt = ?,
                                totalTokens = COALESCE(?, totalTokens), model = COALESCE(?, model)
                            WHERE id = ? AND status = 'assigned'
                        """, arguments: [resultText, now, attributedTokens, attributedModel, eventId])
                    }
                    // Stale/duplicate completion (event already terminal or no
                    // longer owned by this caller): skip the event/task side
                    // effects so we don't disturb the current owner or a
                    // re-dispatched task — BUT still free any worker left pinned
                    // to this non-live event, else its currentEventId sits `busy`
                    // forever (the recurring stuck-busy class). See
                    // reconcilePinnedWorkers.
                    guard db.changesCount > 0 else {
                        try reconcilePinnedWorkers(eventId: eventId, in: db)
                        return (nil, nil)
                    }

                    // Set worker back to idle (unless draining — keep draining status)
                    var captured: String?
                    if let workerId = row?.assignedTo {
                        captured = workerId
                        let workerRow = try Row.fetchOne(db, sql: """
                            SELECT status, currentInputTokens, currentCacheReadTokens, currentPromptHash,
                                   currentSessionLabel, currentCwdBasename
                            FROM workers WHERE workerId = ?
                        """, arguments: [workerId])
                        let workerStatus = workerRow?["status"] as? String
                        let inputTokens = workerRow?["currentInputTokens"] as? Int64
                        let cacheReadTokens = workerRow?["currentCacheReadTokens"] as? Int64
                        let promptHash = workerRow?["currentPromptHash"] as? String
                        let sessionLabel = workerRow?["currentSessionLabel"] as? String
                        let cwdBasename = workerRow?["currentCwdBasename"] as? String

                        // Roll up into promptCacheStats when we have enough data.
                        if let eventType = row?.type,
                           let promptHash, !promptHash.isEmpty,
                           let inputTokens, inputTokens > 0,
                           let cacheReadTokens {
                            let promptKey = "\(eventType):\(promptHash)"
                            try db.execute(sql: """
                                INSERT INTO promptCacheStats
                                    (promptKey, eventType, promptHash, sessionLabel, cwdBasename,
                                     totalInputTokens, totalCacheReadTokens, sampleCount, lastSeenAt)
                                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                                ON CONFLICT(promptKey) DO UPDATE SET
                                    totalInputTokens = totalInputTokens + excluded.totalInputTokens,
                                    totalCacheReadTokens = totalCacheReadTokens + excluded.totalCacheReadTokens,
                                    sampleCount = sampleCount + 1,
                                    sessionLabel = COALESCE(excluded.sessionLabel, sessionLabel),
                                    cwdBasename = COALESCE(excluded.cwdBasename, cwdBasename),
                                    lastSeenAt = excluded.lastSeenAt
                            """, arguments: [promptKey, eventType, promptHash, sessionLabel, cwdBasename,
                                             inputTokens, cacheReadTokens, now])
                        }

                        let newStatus = workerStatus == "draining" ? "draining" : "idle"
                        try db.execute(sql: """
                            UPDATE workers SET
                                status = ?,
                                currentEventId = NULL,
                                currentEventTokens = NULL,
                                currentSlug = NULL,
                                currentCacheReadTokens = NULL,
                                currentInputTokens = NULL,
                                currentPromptHash = NULL,
                                currentSessionLabel = NULL,
                                currentCwdBasename = NULL
                            WHERE workerId = ?
                        """, arguments: [newStatus, workerId])
                    }

                    // Complete associated task + unblock dependents + parent rollup
                    var rotateSidecar: String?
                    if let payload = row?.payload,
                       let payloadData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {

                        // A sidecar that has finished its `rotate_me` event is
                        // telling us it has wound down and is ready to be
                        // replaced. Capture the name; the actual rotation runs
                        // after this transaction commits.
                        //
                        // Completion-side rather than push-side deliberately.
                        // `SidecarLifecycle.rotate` drains by polling
                        // `workers.currentEventId`, and the worker reset above
                        // has just cleared it — so the drain returns
                        // immediately. Rotating when the event was *pushed*
                        // would instead make the sidecar wait out the full
                        // 120s drain timeout on the very event that asked for
                        // the rotation.
                        //
                        // TODO: timeout fallback for wedged sidecar rotation.
                        // If a sidecar never completes its rotate_me — hung, or
                        // crashed after the push — this branch never fires, and
                        // `SidecarLifecycle.rotateRequested` latches the name so
                        // the monitor will not re-post. The sidecar then sits
                        // above its context threshold forever. The fix is a
                        // deadline on the outstanding rotate_me (post time +
                        // grace) after which the lifecycle rotates unilaterally;
                        // out of scope here.
                        if row?.type == "rotate_me",
                           let name = json["sidecar"] as? String, !name.isEmpty {
                            rotateSidecar = name
                        }

                        if let taskId = json["task_id"] as? String {
                            try db.execute(sql: """
                                UPDATE tasks SET status = 'completed', result = ?, completedAt = ?, updatedAt = ?
                                WHERE id = ? AND status = 'active'
                            """, arguments: [resultText ?? "Completed via channel", now, now, taskId])
                            try unblockDependents(taskId: taskId, in: db, now: now)
                            try rollUpParentStatus(childTaskId: taskId, in: db, now: now)
                        }

                        // For email events, mark the dispatched emails as replied so they
                        // don't get re-fired by EmailHandler.dispatchPendingUnreadEmails on restart.
                        if row?.type == "email", let messageIds = json["messageIds"] as? [String], !messageIds.isEmpty {
                            let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")
                            var args: [DatabaseValueConvertible] = ["replied", now]
                            args.append(contentsOf: messageIds)
                            try db.execute(sql: """
                                UPDATE emails SET status = ?, repliedAt = ?
                                WHERE messageId IN (\(placeholders)) AND status = 'unread'
                            """, arguments: StatementArguments(args))
                        }
                    }
                    return (captured, rotateSidecar)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            // Notify WorkerManager for cycling evaluation
            if let wid = completion.workerId {
                DispatchQueue.main.async {
                    WorkerManager.shared.onEventCompleted(workerId: wid)
                }
            }

            // Rotate the sidecar now that its wind-down event is committed.
            // Detached because `rotate` drains, terminates and respawns a whole
            // session: awaiting it here would hold the sidecar's own
            // `complete_event` HTTP response open for the duration, and the
            // session being torn down is the one waiting on that response.
            if let name = completion.rotateSidecar {
                Task.detached {
                    guard let sidecar = SidecarRegistry.shared.lookup(byName: name) else { return }
                    await SidecarRuntime.shared.lifecycle?.rotate(sidecar)
                }
            }

            return SuccessResponse()
        }
    ),

    // POST /api/worker/events/fail — mark event failed, free worker
    SonataAction(
        name: "worker_event_fail",
        description: "Mark a worker event as failed and set worker back to idle.",
        group: "/api/worker/events",
        path: "/fail",
        method: .post,
        params: [
            ActionParam("eventId", .string, required: true, description: "Event ID"),
            ActionParam("workerId", .string, description: "Worker ID (optional)"),
            ActionParam("error", .string, description: "Error description"),
        ],
        handler: { ctx in
            let eventId = try ctx.params.require("eventId")
            let errorText = ctx.params.string("error")
            let now = nowMs()
            let completedWorkerId: String?
            do {
                completedWorkerId = try await ctx.dbPool.write { db -> String? in
                    let row = try WorkerEventRow.fetchOne(db,
                        sql: "SELECT * FROM workerEvents WHERE id = ?",
                        arguments: [eventId])

                    // Same token attribution as the complete path — failures still
                    // burned tokens and should show up in the Dashboard cost card.
                    var attributedTokens: Int64?
                    var attributedModel: String?
                    if let workerId = row?.assignedTo {
                        let tokRow = try Row.fetchOne(db, sql: """
                            SELECT currentEventTokens FROM workers WHERE workerId = ?
                        """, arguments: [workerId])
                        attributedTokens = tokRow?["currentEventTokens"] as? Int64
                    }
                    if let payload = row?.payload,
                       let payloadData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                       let m = json["model"] as? String, !m.isEmpty {
                        attributedModel = m
                    }
                    if attributedModel == nil { attributedModel = ModelPricing.defaultModel }

                    // Owner-guard (see worker_event_complete): only fail the
                    // event if it is still 'assigned' to THIS caller. A stale
                    // fail from a zombie session must not free the worker that
                    // currently owns a re-dispatched event, nor re-fail a task
                    // that has already moved on. Legacy callers without a
                    // workerId fall back to the status guard alone.
                    let callerWorkerId = ctx.params.string("workerId")
                    if let callerWorkerId, !callerWorkerId.isEmpty {
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET status = 'failed', result = ?, completedAt = ?,
                                totalTokens = COALESCE(?, totalTokens), model = COALESCE(?, model)
                            WHERE id = ? AND status = 'assigned' AND assignedTo = ?
                        """, arguments: [errorText, now, attributedTokens, attributedModel, eventId, callerWorkerId])
                    } else {
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET status = 'failed', result = ?, completedAt = ?,
                                totalTokens = COALESCE(?, totalTokens), model = COALESCE(?, model)
                            WHERE id = ? AND status = 'assigned'
                        """, arguments: [errorText, now, attributedTokens, attributedModel, eventId])
                    }
                    // Stale/duplicate fail: skip event/task side effects (see
                    // complete path) but still free any worker left pinned to
                    // this non-live event (recurring stuck-busy class).
                    guard db.changesCount > 0 else {
                        try reconcilePinnedWorkers(eventId: eventId, in: db)
                        return nil
                    }

                    var captured: String?
                    if let workerId = row?.assignedTo {
                        captured = workerId
                        let workerRow = try Row.fetchOne(db, sql: """
                            SELECT status, currentInputTokens, currentCacheReadTokens, currentPromptHash,
                                   currentSessionLabel, currentCwdBasename
                            FROM workers WHERE workerId = ?
                        """, arguments: [workerId])
                        let workerStatus = workerRow?["status"] as? String
                        let inputTokens = workerRow?["currentInputTokens"] as? Int64
                        let cacheReadTokens = workerRow?["currentCacheReadTokens"] as? Int64
                        let promptHash = workerRow?["currentPromptHash"] as? String
                        let sessionLabel = workerRow?["currentSessionLabel"] as? String
                        let cwdBasename = workerRow?["currentCwdBasename"] as? String

                        // Roll up into promptCacheStats — failures still consumed tokens.
                        if let eventType = row?.type,
                           let promptHash, !promptHash.isEmpty,
                           let inputTokens, inputTokens > 0,
                           let cacheReadTokens {
                            let promptKey = "\(eventType):\(promptHash)"
                            try db.execute(sql: """
                                INSERT INTO promptCacheStats
                                    (promptKey, eventType, promptHash, sessionLabel, cwdBasename,
                                     totalInputTokens, totalCacheReadTokens, sampleCount, lastSeenAt)
                                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                                ON CONFLICT(promptKey) DO UPDATE SET
                                    totalInputTokens = totalInputTokens + excluded.totalInputTokens,
                                    totalCacheReadTokens = totalCacheReadTokens + excluded.totalCacheReadTokens,
                                    sampleCount = sampleCount + 1,
                                    sessionLabel = COALESCE(excluded.sessionLabel, sessionLabel),
                                    cwdBasename = COALESCE(excluded.cwdBasename, cwdBasename),
                                    lastSeenAt = excluded.lastSeenAt
                            """, arguments: [promptKey, eventType, promptHash, sessionLabel, cwdBasename,
                                             inputTokens, cacheReadTokens, now])
                        }

                        let newStatus = workerStatus == "draining" ? "draining" : "idle"
                        try db.execute(sql: """
                            UPDATE workers SET
                                status = ?,
                                currentEventId = NULL,
                                currentEventTokens = NULL,
                                currentSlug = NULL,
                                currentCacheReadTokens = NULL,
                                currentInputTokens = NULL,
                                currentPromptHash = NULL,
                                currentSessionLabel = NULL,
                                currentCwdBasename = NULL
                            WHERE workerId = ?
                        """, arguments: [newStatus, workerId])
                    }

                    // Fail associated task + unblock dependents + parent rollup
                    if let payload = row?.payload,
                       let payloadData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                       let taskId = json["task_id"] as? String {
                        try db.execute(sql: """
                            UPDATE tasks SET status = 'failed', lastError = ?, updatedAt = ?
                            WHERE id = ? AND status = 'active'
                        """, arguments: [errorText ?? "Failed via channel", now, taskId])
                        try unblockDependents(taskId: taskId, in: db, now: now)
                        try rollUpParentStatus(childTaskId: taskId, in: db, now: now)
                    }
                    return captured
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            // Notify WorkerManager for cycling evaluation
            if let wid = completedWorkerId {
                DispatchQueue.main.async {
                    WorkerManager.shared.onEventCompleted(workerId: wid)
                }
            }

            return SuccessResponse()
        }
    ),

    // GET /api/worker/events/recent — list recent worker events
    SonataAction(
        name: "worker_event_recent",
        description: "List recent worker events ordered by createdAt DESC. Optional task_id filter narrows to events whose payload references that task.",
        group: "/api/worker/events",
        path: "/recent",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 20)"),
            ActionParam("task_id", .string, description: "If set, only return events whose payload contains this task_id"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 20
            let taskId = ctx.params.string("task_id")
            do {
                let rows = try await ctx.dbPool.read { db -> [WorkerEventRow] in
                    if let taskId, !taskId.isEmpty {
                        // Filter server-side so high-volume inboxes (email events) don't
                        // push older task events out of the recent window.
                        let needle = "%\"task_id\":\"\(taskId)\"%"
                        return try WorkerEventRow.fetchAll(db,
                            sql: "SELECT * FROM workerEvents WHERE payload LIKE ? ORDER BY createdAt DESC LIMIT ?",
                            arguments: [needle, limit])
                    }
                    return try WorkerEventRow.fetchAll(db,
                        sql: "SELECT * FROM workerEvents ORDER BY createdAt DESC LIMIT ?",
                        arguments: [limit])
                }
                return rows.map { eventToResponse($0) }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
