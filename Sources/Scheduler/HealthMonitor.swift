import Foundation
import GRDB
import Logging

/// Periodic health monitoring for Sonata services.
///
/// Checks every 60 seconds:
/// - SQLite database accessible
/// - HTTP server responding
/// - Scheduler running
/// - Disk space on data volume
///
/// Tracks SDK session outcomes per label, detects repeated failures,
/// and sends alerts via AgentMail when consecutive failures exceed threshold.
actor HealthMonitor {

    // MARK: - Configuration

    /// How often to run health checks (seconds).
    private let checkInterval: TimeInterval = 60

    /// Minimum free disk space before warning (bytes). 10 GB.
    private let minFreeDiskBytes: UInt64 = 10 * 1024 * 1024 * 1024

    /// Consecutive failures before sending an alert.
    private let alertThreshold: Int = 3

    /// AgentMail configuration for alerts — resolved from DB at send time.
    private var alertFromEmail: String?
    private var alertToEmail: String?

    /// HTTP server URL to check.
    private let serverURL: String

    // MARK: - State

    private let dbPool: DatabasePool
    private let emailProvider: EmailProvider
    private let logger: Logger
    private var monitorTask: Task<Void, Never>?
    private var isRunning = false

    /// Search backend, for the index-drift reconcile check (nil = skip it).
    private let search: (any SearchService)?
    /// Wall-clock gate for the heavier search-index reconcile (scans dirs + may
    /// re-backfill), so it runs at most once per interval no matter how often
    /// runAllChecks is invoked — an /api/status call must not perturb the
    /// cadence or trigger a backfill inside a status response.
    private var lastSearchCheckAt: Date = .distantPast
    private let searchCheckInterval: TimeInterval = 600  // 10 min

    /// Consecutive failure counts by check name.
    private var consecutiveFailures: [String: Int] = [:]

    /// Session outcome tracking: label → (successes, failures).
    private var sessionOutcomes: [String: (successes: Int, failures: Int)] = [:]

    /// Base interval before the FIRST repeat of an unchanged alert (5 minutes).
    /// Repeats then back off exponentially up to `alertMaxInterval`.
    private let alertCooldown: TimeInterval = 300

    /// Hard ceiling on the interval between repeat alerts for an unchanged
    /// condition. Without this, a persistently-failing check re-emails at the
    /// 5-min cadence forever — on 2026-06-21 a stuck disk_space reading sent
    /// Evan 1153 near-identical alerts over ~19h. With exponential backoff
    /// capped here, the same condition emails ~20×, each a digest.
    private let alertMaxInterval: TimeInterval = 3600

    /// Per-check alert dedup state, keyed by check name. An alert fires
    /// immediately when the condition is NEW or its signature CHANGES; an
    /// unchanged condition is throttled with exponential backoff.
    private struct AlertState {
        var signature: String        // count-free fingerprint of the condition
        var firstSentAt: Date
        var lastSentAt: Date
        var sentCount: Int           // emails actually sent for this signature
        var suppressedSinceLast: Int // checks observed since the last email
    }
    private var alertStates: [String: AlertState] = [:]

    /// A worker is considered "stuck" if it's been on the same event without
    /// progress for this long. The bridge heartbeats every 15s, so any worker
    /// here is alive — but its state machine isn't progressing the work. Evan
    /// observed this pattern repeatedly on 2026-06-22: workers completing
    /// tasks but never flipping status from 'busy', or claiming events but
    /// never starting them. A "Continue" DM nudges the underlying agent loop
    /// back into action without touching state in the DB (which is the cheap,
    /// correct response — let the worker drive its own state machine).
    private let workerStuckThreshold: TimeInterval = 5 * 60   // 5 min no progress
    /// Worker must have heartbeated this recently to still be "alive" and
    /// worth nudging. Past this it's the reaper's job, not the nudger's.
    private let workerHeartbeatFreshness: TimeInterval = 90   // 90s
    /// TTL for an un-replied sonar_dm workerEvent. A DM event stays `assigned`
    /// only to hold the worker busy while it drafts a reply and to let
    /// dm_reply's auto-complete fire. If neither happens within this window the
    /// DM was handled-without-reply, the worker died, or the auto-complete
    /// missed — sweepStaleDMEvents closes it and frees the worker. 30 min
    /// (Evan, 2026-07-17): long enough that a genuine slow reply is never at risk.
    private let sonarDMTtl: TimeInterval = 30 * 60
    /// Don't re-nudge the same worker more often than this.
    private let workerNudgeCooldown: TimeInterval = 5 * 60    // 5 min

    /// In-memory dedup for nudges: workerId → last nudge timestamp. Reset on
    /// process restart, which is intentional — a fresh boot wants to re-evaluate
    /// every stuck worker from scratch (the on-boot sweep Evan asked for).
    private var lastWorkerNudgeAt: [String: Date] = [:]

    /// Grace period between "flagged offline" and destructive reap. The sweep
    /// only sets status='offline' now — an ALERT, not an action. The
    /// escalation loop DMs the worker as a second-signal liveness check and
    /// waits this long for recovery. Fix #2 in worker_heartbeat lets a
    /// heartbeat un-stick 'offline' back to 'busy'/'idle', so a false-positive
    /// sweep flip self-heals in the normal case. Only the persistently-quiet
    /// worker (or one whose SSE is also dead — two negative signals, no
    /// grace) gets reaped.
    private let offlineGracePeriod: TimeInterval = 5 * 60

    /// Per-worker escalation state for the offline reap ladder. Reset on
    /// process restart. Cleared for a workerId whenever that worker's DB
    /// status transitions out of 'offline' (recovery) or the deadline fires
    /// (reap).
    private struct OfflineEscalation {
        let firstOfflineAt: Date
        let dmSentAt: Date?
        let deadline: Date
    }
    private var offlineEscalations: [String: OfflineEscalation] = [:]

    /// Fallback interval between supervisor check-event pushes (3 minutes).
    /// Only used if the supervisorConfig singleton row cannot be read.
    private let fallbackSupervisorCheckInterval: TimeInterval = 180

    /// Last time a supervisor check event was pushed.
    private var lastSupervisorCheckPushedAt: Date?

    /// Cached snapshot of the supervisorConfig singleton (refreshed each loop).
    private struct SupervisorSchedule {
        var dayIntervalSec: Int
        var nightIntervalSec: Int
        var nightStartHour: Int
        var nightEndHour: Int
        var enabled: Bool
    }

    /// Weak reference to the scheduler for status checks.
    private let schedulerStatus: (@Sendable () async -> Bool)?

    /// Hand a workerId to the pool for a full drain+respawn (SIGTERM the
    /// existing claude PTY, spawn a replacement in the same slot). Called by
    /// the reaper when it fails an overdue task so a wedged worker actually
    /// gets replaced instead of being handed a fresh event it can't process.
    /// Optional — nil in test harnesses that don't boot a WorkerManager.
    private let cycleStuckWorkers: (@Sendable ([String]) async -> Void)?

    /// Returns `(target, effective)` for the worker pool. `effective` is the
    /// count of workers in a non-terminal status (i.e. NOT `.offline`).
    /// Optional — when nil, the worker_pool check is skipped (e.g. in test
    /// harnesses that don't boot a WorkerManager).
    private let workerPoolStatus: (@Sendable () async -> (target: Int, effective: Int))?

    /// First time `workerPoolStatus` reported effective < target with no
    /// subsequent recovery. Cleared the moment effective >= target. Used to
    /// distinguish a transient dip (single tick) from a stuck pool (>5 min)
    /// — only the latter triggers the unhealthy CheckResult.
    private var poolUnderTargetSince: Date?

    /// Grace period: how long the pool may run below target before the
    /// `worker_pool` check goes unhealthy. 2026-05-18 incident headline:
    /// "you'll get paged in under 10 min if pool stalls" — combined with
    /// the existing 3-strike alertThreshold and 60s checkInterval this
    /// puts a hard upper bound on time-to-alert. Backstop only; the real
    /// fixes live in WorkerManager.
    private let poolUnderTargetGrace: TimeInterval = 300

    // MARK: - Health Check Result

    struct CheckResult: Sendable {
        let name: String
        let healthy: Bool
        let message: String
        let timestamp: Date
    }

    /// Snapshot of all health checks.
    struct HealthSnapshot: Sendable {
        let checks: [CheckResult]
        let sessionOutcomes: [String: (successes: Int, failures: Int)]
        let overallHealthy: Bool
        let timestamp: Date
    }

    // MARK: - Init

    /// Initialize the health monitor.
    ///
    /// - Parameters:
    ///   - dbPool: Database pool to check.
    ///   - port: HTTP server port to check.
    ///   - schedulerStatus: Closure that returns whether the scheduler is running.
    ///   - logger: Optional logger.
    init(
        dbPool: DatabasePool,
        port: Int = 3212,
        schedulerStatus: (@Sendable () async -> Bool)? = nil,
        workerPoolStatus: (@Sendable () async -> (target: Int, effective: Int))? = nil,
        cycleStuckWorkers: (@Sendable ([String]) async -> Void)? = nil,
        emailProvider: EmailProvider = AgentMailProvider(),
        search: (any SearchService)? = nil,
        logger: Logger? = nil
    ) {
        self.dbPool = dbPool
        self.emailProvider = emailProvider
        self.serverURL = "http://127.0.0.1:\(port)/api/ping"
        self.schedulerStatus = schedulerStatus
        self.workerPoolStatus = workerPoolStatus
        self.cycleStuckWorkers = cycleStuckWorkers
        self.search = search
        var log = logger ?? Logger(label: "sonata.health")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Lifecycle

    /// Start periodic health monitoring.
    func start() {
        guard !isRunning else {
            logger.warning("HealthMonitor already running — ignoring duplicate start()")
            return
        }
        isRunning = true
        logger.info("HealthMonitor started (interval: \(Int(checkInterval))s)")

        monitorTask = Task { [weak self] in
            await self?.monitorLoop()
        }
    }

    /// Stop health monitoring.
    func shutdown() {
        logger.info("HealthMonitor shutting down")
        monitorTask?.cancel()
        monitorTask = nil
        isRunning = false
    }

    /// Record a session outcome for tracking.
    func recordSessionOutcome(label: String, success: Bool) {
        var entry = sessionOutcomes[label] ?? (successes: 0, failures: 0)
        if success {
            entry.successes += 1
        } else {
            entry.failures += 1
        }
        sessionOutcomes[label] = entry

        // Detect repeated failures
        if !success {
            let total = entry.failures
            if total > 0 && total % alertThreshold == 0 {
                logger.warning("Session label '\(label)' has \(total) total failures")
                Task { [weak self] in
                    await self?.sendAlert(
                        check: "session:\(label)",
                        message: "Claude session label '\(label)' has accumulated \(total) failures (vs \(entry.successes) successes)"
                    )
                }
            }
        }
    }

    /// Get a snapshot of current health status (for the /api/status endpoint).
    func snapshot() async -> HealthSnapshot {
        let checks = await runAllChecks()
        let allHealthy = checks.allSatisfy(\.healthy)
        return HealthSnapshot(
            checks: checks,
            sessionOutcomes: sessionOutcomes,
            overallHealthy: allHealthy,
            timestamp: Date()
        )
    }

    // MARK: - Monitor Loop

    private func monitorLoop() async {
        while !Task.isCancelled {
            let checks = await runAllChecks()

            for check in checks {
                if check.healthy {
                    // Reset consecutive failures on success, and emit a one-shot
                    // all-clear if we had been alerting on this check.
                    consecutiveFailures[check.name] = 0
                    await noteRecovery(check: check.name)
                } else {
                    let count = (consecutiveFailures[check.name] ?? 0) + 1
                    consecutiveFailures[check.name] = count

                    logger.warning("Health check '\(check.name)' failed (\(count)x): \(check.message)")

                    if count >= alertThreshold {
                        // Pass the underlying check message as the dedup
                        // signature — NOT the string above, whose embedded
                        // count changes every cycle and would defeat dedup.
                        await sendAlert(
                            check: check.name,
                            message: "Health check '\(check.name)' has failed \(count) consecutive times: \(check.message)",
                            signature: check.message
                        )
                        postDistributedNotification(check: check.name, message: check.message)
                    }
                }
            }

            let failedChecks = checks.filter { !$0.healthy }
            if failedChecks.isEmpty {
                logger.debug("All health checks passed")
            } else {
                logger.warning("\(failedChecks.count) health check(s) failed: \(failedChecks.map(\.name).joined(separator: ", "))")
            }

            // Nudge any workers that look stuck on the current event.
            // GATED OFF until the bridge bumps `lastProgressMs` on every tool
            // call. Today, that signal only updates in complete_event /
            // fail_event handlers, so a worker chugging through tool calls
            // looks "stuck" to the nudger and gets interrupted with a useless
            // "Continue" DM. Flip SONA_WORKER_NUDGE=1 once the bridge fix lands.
            if ProcessInfo.processInfo.environment["SONA_WORKER_NUDGE"] == "1" {
                await nudgeStuckWorkers()
            }

            // Self-heal stranded events every cycle (always on, unlike the
            // nudge above). A worker holding an event whose SSE push was lost
            // never completes it, and no heartbeat-based sweep catches it
            // (the bridge keeps heartbeating). Reclaim it within one monitor
            // cycle instead of waiting for the 30/75-min supervisor pass.
            await reclaimStrandedEvents()

            // Ghost worker process sweep. `pgrep -f mcp-cfg/worker-*.json`
            // enumerates every claude worker process on the host;
            // cross-referenced with the workers table, anything unregistered
            // and older than 30s gets SIGTERM/SIGKILL. Catches (a) Sonata
            // restart survivors, (b) processes leaked by removeWorker's
            // nil-shellPid failure mode (weak var terminalView collapses
            // when SwiftUI releases the view — kill path silently no-ops).
            _ = await GhostWorkerReaper.reap(dbPool: dbPool, logger: logger, source: "monitor")

            // Orphan-event sweep. When sweepStaleWorkersForActions was
            // gutted to alert-only (d179191), it stopped failing/re-enqueueing
            // events on stale heartbeat. The escalation ladder covers workers
            // still in the DB; but workers deleted via UI kill / worker_purge /
            // predecessor-cleanup vanish from the workers table entirely, and
            // any workerEvents still `assigned` to their dead workerIds have
            // NO reaper. Left uncleaned, they accumulate (41 rows from April-May
            // observed 2026-07-07) and get resurrected onto fresh spawns via
            // predecessor-cleanup's `SET status='pending'` release path —
            // "phantom tasks" pinning new workers. This sweep cancels those
            // orphans within one monitor cycle.
            await sweepOrphanedEvents()

            // Close sonar_dm workerEvents that have sat `assigned` past the TTL
            // with no reply, freeing their workers. Distinct from the two
            // sweeps above: a stale DM is CLOSED, never re-enqueued (requeuing
            // would re-deliver the message to a second worker → crosstalk).
            // Backstops the dm_reply auto-complete for DMs that are handled
            // without a reply, whose worker died, or where the auto-complete
            // missed (2026-07-17).
            await sweepStaleDMEvents()

            // Offline escalation ladder. sweepStaleWorkersForActions now only
            // MARKS workers offline (Fix #3 in dispatch-hardening-bundle) — it
            // no longer flips events or tasks. This loop reads the offline
            // signal, DMs the worker as a second-signal liveness check, and
            // reaps only after grace passes without recovery. Prevents the
            // "busy worker briefly quiet → tasks re-enqueued → duplicate
            // dispatch" class that produced the wiki-compilation dupe
            // 2026-07-07.
            await escalateOfflineWorkers()

            // Deterministic wall-clock timeout enforcement — fail any active
            // task past its metadata.timeoutSeconds and recycle the pool worker
            // holding it. Always on and independent of supervisor-session
            // liveness, so an overnight gap with no live session can't let a
            // task overrun for hours before a waking session batch-kills the
            // whole backlog at once with inconsistent error text.
            await reapOverdueTasks()

            // Push a periodic check event to the supervisor, driven by
            // the configurable day/night schedule in supervisorConfig.
            let schedule = await loadSupervisorSchedule()
            if schedule.enabled {
                let interval = currentSupervisorInterval(schedule: schedule)
                if lastSupervisorCheckPushedAt.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
                    await pushSupervisorCheck()
                    lastSupervisorCheckPushedAt = Date()
                }
            }

            do {
                try await Task.sleep(for: .seconds(checkInterval))
            } catch {
                break  // Cancelled
            }
        }
    }

    // MARK: - Supervisor Schedule

    /// Load the supervisorConfig singleton. Falls back to built-in defaults
    /// (day 180s, night 1800s, 22→07, enabled) if the row is missing or
    /// the DB read fails.
    private func loadSupervisorSchedule() async -> SupervisorSchedule {
        do {
            let row: Row? = try dbPool.read { db -> Row? in
                try Row.fetchOne(db, sql: """
                    SELECT dayIntervalSec, nightIntervalSec, nightStartHour,
                           nightEndHour, enabled
                    FROM supervisorConfig WHERE id = 'singleton'
                """)
            }
            if let row {
                return SupervisorSchedule(
                    dayIntervalSec: Int((row["dayIntervalSec"] as Int64?) ?? Int64(fallbackSupervisorCheckInterval)),
                    nightIntervalSec: Int((row["nightIntervalSec"] as Int64?) ?? 1800),
                    nightStartHour: Int((row["nightStartHour"] as Int64?) ?? 22),
                    nightEndHour: Int((row["nightEndHour"] as Int64?) ?? 7),
                    enabled: ((row["enabled"] as Int64?) ?? 1) != 0
                )
            }
        } catch {
            logger.warning("Could not read supervisorConfig (\(error.localizedDescription)) — using defaults")
        }
        return SupervisorSchedule(
            dayIntervalSec: Int(fallbackSupervisorCheckInterval),
            nightIntervalSec: 1800,
            nightStartHour: 22,
            nightEndHour: 7,
            enabled: true
        )
    }

    /// Resolve the effective push interval for the current wall-clock hour.
    /// Day vs night is selected by the configured night window; the window
    /// wraps at midnight when nightStartHour > nightEndHour (e.g. 22→07).
    private func currentSupervisorInterval(schedule: SupervisorSchedule) -> TimeInterval {
        let hour = Calendar.current.component(.hour, from: Date())
        let start = schedule.nightStartHour
        let end = schedule.nightEndHour
        let isNight: Bool
        if start == end {
            isNight = false
        } else if start < end {
            isNight = hour >= start && hour < end
        } else {
            isNight = hour >= start || hour < end
        }
        return TimeInterval(isNight ? schedule.nightIntervalSec : schedule.dayIntervalSec)
    }

    // MARK: - Supervisor Push

    /// Insert a 'check' event into supervisorEvents if the supervisor is running
    /// (lastHeartbeat within the past 60s). Skips if offline — no point queuing
    /// work for a session that isn't listening.
    private func pushSupervisorCheck() async {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let running = (try? await dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM supervisorState WHERE lastHeartbeat >= ?
            """, arguments: [cutoff])
        }) ?? false

        guard running == true else { return }

        do {
            try await dbPool.write { db in
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                try db.execute(sql: """
                    INSERT INTO supervisorEvents (id, type, payload, createdAt)
                    VALUES (?, 'check', '{}', ?)
                """, arguments: [UUID().uuidString.lowercased(), now])
            }
            logger.debug("Pushed supervisor check event")
        } catch {
            logger.warning("Failed to push supervisor check: \(error.localizedDescription)")
        }
    }

    // MARK: - Health Checks

    private func runAllChecks() async -> [CheckResult] {
        let now = Date()
        var results: [CheckResult] = []

        // 1. SQLite database accessible
        results.append(await checkDatabase(at: now))

        // 2. HTTP server responding
        results.append(await checkHTTPServer(at: now))

        // 3. Scheduler running
        results.append(await checkScheduler(at: now))

        // 4. Disk space
        results.append(checkDiskSpace(at: now))

        // 5. Worker pool size (backstop for 2026-05-18 auto-spawn flake).
        // Skipped silently when no provider is configured (test harnesses).
        if let poolResult = await checkWorkerPool(at: now) {
            results.append(poolResult)
        }

        // 6. Search-index + embedding coverage reconcile. Heavier (scans dirs,
        // may re-backfill), so only every Nth tick. This is the standing guard
        // against the silent-drift class — embeddings not generating, a Meili
        // index falling behind its source — that previously went unnoticed for
        // weeks (vector dark 5/18→6/12; docs index drifting with no watcher).
        if search != nil, now.timeIntervalSince(lastSearchCheckAt) >= searchCheckInterval {
            lastSearchCheckAt = now
            results.append(contentsOf: await checkSearchAndEmbeddings(at: now))
        }

        return results
    }

    // MARK: - Search index + embedding coverage

    /// Source-of-truth counts for each retrieval surface, compared against what
    /// the index actually holds. Self-heals the one surface with no live writer
    /// (docs: re-backfilled when short — there is no FSEvents watcher on the
    /// documents dir, unlike wiki/private). Everything reports drift into the
    /// existing consecutive-failure alert → supervisor path, so a wedged
    /// sweeper or watcher pages within minutes instead of going unnoticed.
    private func checkSearchAndEmbeddings(at time: Date) async -> [CheckResult] {
        guard let search else { return [] }
        var out: [CheckResult] = []

        // --- Embedding coverage (active memories must have a vector) ---
        let missingEmbeddings = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM memories m
                WHERE COALESCE(m.status,'active')='active'
                  AND NOT EXISTS (SELECT 1 FROM memoryEmbeddings e WHERE e.memoryId = m.id)
                """) ?? 0
        }) ?? 0
        // EmbeddingSweeper drains the backlog continuously; a small transient
        // count is normal. A large standing gap means it's wedged.
        out.append(CheckResult(
            name: "embedding_coverage",
            healthy: missingEmbeddings <= 50,
            message: missingEmbeddings <= 50
                ? "OK (\(missingEmbeddings) active unembedded)"
                : "\(missingEmbeddings) active memories have no embedding — vector recall is blind to them (EmbeddingSweeper wedged?)",
            timestamp: time))

        // --- Meili index drift vs source of truth ---
        // (index, sourceCount, healWhenShort)
        struct IndexCheck { let name: String; let source: Int; let heal: (@Sendable () async -> Void)? }
        let archiveCount = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories WHERE status IN ('archived','superseded')") ?? 0
        }) ?? 0
        // Wiki is indexed from the wikiPages TABLE (non-archived), not raw
        // disk — so compare against the table, else unregistered .md files on
        // disk read as false "missing".
        let wikiPageCount = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wikiPages WHERE pageType IS NULL OR pageType != 'archived'") ?? 0
        }) ?? 0
        let emailCount = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails") ?? 0
        }) ?? 0
        // sessions index doc ≈ one per recorded transcript chunk.
        let sessionChunkCount = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(chunkCount),0) FROM transcriptIndexState") ?? 0
        }) ?? 0
        let dbPoolRef = dbPool
        // wiki/private heal via FSEvents (WikiFileWatcher); emails/sessions via
        // ConversationIndexer's own sweep — so those are alarm-only here and a
        // breach means that writer is wedged. docs/archive have no live writer,
        // so they self-heal from their authoritative backfill.
        let checks: [IndexCheck] = [
            IndexCheck(name: "wiki", source: wikiPageCount, heal: nil),
            IndexCheck(name: "docs", source: Self.countFiles(SonataInstance.dataDirectory + "/documents", exts: ["md","txt"]),
                       heal: { await search.backfillDocs() }),
            IndexCheck(name: "private", source: Self.countFiles(SonataInstance.dataDirectory + "/private", exts: ["md","txt"]), heal: nil),
            IndexCheck(name: "emails", source: emailCount, heal: nil),
            IndexCheck(name: "sessions", source: sessionChunkCount, heal: nil),
            // archive heals BOTH directions: backfill adds missing, prune
            // removes orphans (deleted memories backfill never cleans up).
            IndexCheck(name: "archive", source: archiveCount, heal: {
                await search.backfillArchive(dbPool: dbPoolRef)
                _ = await search.pruneArchiveOrphans(dbPool: dbPoolRef)
            }),
        ]

        for c in checks {
            let indexed = await search.documentCount(index: c.name)
            // documentCount returns -1 when Meili is unreachable; that's the
            // http/meili layer's problem, not a drift signal — skip.
            guard indexed >= 0 else { continue }
            // Drift in EITHER direction: under-count = missing docs, over-count
            // = orphans (deleted sources never pruned). Alarm beyond tolerance.
            let drift = abs(c.source - indexed)
            let tolerance = max(5, c.source / 20)  // 5%, min 5
            if drift > tolerance, let heal = c.heal {
                logger.warning("search index '\(c.name)' drift \(indexed) vs source \(c.source) — reconciling")
                await heal()
            }
            out.append(CheckResult(
                name: "index_\(c.name)",
                healthy: drift <= tolerance,
                message: drift <= tolerance
                    ? "OK (\(indexed)/\(c.source))"
                    : "index drift \(indexed)/\(c.source)\(c.heal != nil ? " — heal triggered" : " — no auto-heal")",
                timestamp: time))
        }

        return out
    }

    /// Recursive count of files with the given extensions under `root`.
    private static func countFiles(_ root: String, exts: Set<String>) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return 0 }
        var n = 0
        while let rel = en.nextObject() as? String {
            if exts.contains((rel as NSString).pathExtension.lowercased()) { n += 1 }
        }
        return n
    }

    /// Returns `nil` when no pool-status provider is configured (test mode).
    /// Otherwise: healthy iff effective >= target OR effective < target for
    /// less than `poolUnderTargetGrace`. Unhealthy results feed the existing
    /// consecutive-failure alert path.
    private func checkWorkerPool(at time: Date) async -> CheckResult? {
        guard let provider = workerPoolStatus else { return nil }
        let snapshot = await provider()
        if snapshot.effective >= snapshot.target {
            poolUnderTargetSince = nil
            return CheckResult(
                name: "worker_pool",
                healthy: true,
                message: "OK (\(snapshot.effective)/\(snapshot.target))",
                timestamp: time
            )
        }
        let stuckSince = poolUnderTargetSince ?? time
        poolUnderTargetSince = stuckSince
        let elapsed = time.timeIntervalSince(stuckSince)
        if elapsed < poolUnderTargetGrace {
            return CheckResult(
                name: "worker_pool",
                healthy: true,
                message: "under-target \(Int(elapsed))s grace (\(snapshot.effective)/\(snapshot.target))",
                timestamp: time
            )
        }
        return CheckResult(
            name: "worker_pool",
            healthy: false,
            message: "Pool below target for \(Int(elapsed))s: \(snapshot.effective)/\(snapshot.target)",
            timestamp: time
        )
    }

    /// Test-only knob: prime the stuck-since clock so unit tests can exercise
    /// the past-grace branch without sleeping for 5 minutes of wall time.
    func setPoolUnderTargetSinceForTesting(_ date: Date?) {
        poolUnderTargetSince = date
    }

    /// Test-only invoker for `checkWorkerPool` (private otherwise).
    func runWorkerPoolCheckForTesting(at time: Date = Date()) async -> CheckResult? {
        await checkWorkerPool(at: time)
    }

    /// Check that SQLite is accessible by running a simple query.
    private func checkDatabase(at time: Date) async -> CheckResult {
        do {
            let count = try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories")
            }
            return CheckResult(
                name: "database",
                healthy: true,
                message: "OK (\(count ?? 0) memories)",
                timestamp: time
            )
        } catch {
            return CheckResult(
                name: "database",
                healthy: false,
                message: "Database error: \(error.localizedDescription)",
                timestamp: time
            )
        }
    }

    /// Check that the HTTP server is responding to /api/ping.
    private func checkHTTPServer(at time: Date) async -> CheckResult {
        guard let url = URL(string: serverURL) else {
            return CheckResult(name: "http_server", healthy: false, message: "Invalid URL", timestamp: time)
        }

        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(from: url)

            guard let http = response as? HTTPURLResponse else {
                return CheckResult(name: "http_server", healthy: false, message: "Non-HTTP response", timestamp: time)
            }

            if http.statusCode == 200 {
                // Verify it's actually our server
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["pong"] as? Bool == true {
                    return CheckResult(name: "http_server", healthy: true, message: "OK", timestamp: time)
                }
                return CheckResult(name: "http_server", healthy: false, message: "Unexpected response body", timestamp: time)
            } else {
                return CheckResult(name: "http_server", healthy: false, message: "HTTP \(http.statusCode)", timestamp: time)
            }
        } catch {
            return CheckResult(name: "http_server", healthy: false, message: "Connection failed: \(error.localizedDescription)", timestamp: time)
        }
    }

    /// Check that the scheduler actor is running.
    private func checkScheduler(at time: Date) async -> CheckResult {
        if let statusFn = schedulerStatus {
            let running = await statusFn()
            return CheckResult(
                name: "scheduler",
                healthy: running,
                message: running ? "OK" : "Scheduler not running",
                timestamp: time
            )
        }
        // No status function provided — can't check, assume OK
        return CheckResult(name: "scheduler", healthy: true, message: "OK (no status hook)", timestamp: time)
    }

    /// Check available disk space on the data volume.
    ///
    /// Reads free space TWO independent ways and trusts the larger. On
    /// 2026-06-21 `.systemFreeSize` reported 0.3 GB free on a volume that
    /// `df` showed with 123 GB free, and the monitor then alerted 1153×. A
    /// single spuriously-low statfs read must not be able to wedge the verdict,
    /// so we cross-check it against `volumeAvailableCapacityForImportantUsage`.
    private func checkDiskSpace(at time: Date) -> CheckResult {
        let dataDir = SonataInstance.dataDirectory
        let viaAttrs = freeBytesViaAttributes(dataDir)
        let viaURL = freeBytesViaResourceValues(dataDir)

        let candidates = [viaAttrs, viaURL].compactMap { $0 }
        guard let freeSpace = candidates.max() else {
            return CheckResult(name: "disk_space", healthy: false, message: "Could not read free space", timestamp: time)
        }

        // If the two reads disagree sharply, the low one is suspect — keep the
        // larger (done above) but log the divergence so it's diagnosable.
        if let a = viaAttrs, let b = viaURL {
            let lo = min(a, b), hi = max(a, b)
            if (lo == 0 && hi > 0) || (lo > 0 && hi / lo >= 2) {
                logger.warning("disk_space reads diverge (attrs=\(a) url=\(b)) — trusting larger (\(hi))")
            }
        }

        let freeGB = Double(freeSpace) / (1024 * 1024 * 1024)
        let healthy = freeSpace >= minFreeDiskBytes
        let message = healthy
            ? String(format: "OK (%.1f GB free)", freeGB)
            : String(format: "Low disk space: %.1f GB free (< 10 GB)", freeGB)

        return CheckResult(name: "disk_space", healthy: healthy, message: message, timestamp: time)
    }

    /// Free bytes via `statfs` (classic POSIX free-block count).
    private func freeBytesViaAttributes(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: path))?[.systemFreeSize] as? UInt64
    }

    /// Free bytes via the modern URL resource API. On APFS this reports
    /// capacity available for "important" usage (includes reclaimable/purgeable
    /// space) and is the value the OS itself uses — a good independent witness.
    private func freeBytesViaResourceValues(_ path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path)
        let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = vals?.volumeAvailableCapacityForImportantUsage, bytes >= 0 else { return nil }
        return UInt64(bytes)
    }

    // MARK: - Alerts

    /// Resolve alert email addresses from the first enabled inbox in the DB.
    private func resolveAlertEmails() async {
        if alertFromEmail != nil { return }
        do {
            let inbox: (address: String, role: String)? = try await dbPool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT address, role FROM emailInboxes
                    WHERE enabled = 1 ORDER BY createdAt ASC LIMIT 1
                """).map { (address: $0["address"] as String, role: $0["role"] as String) }
            }
            if let inbox {
                alertFromEmail = inbox.address
                // Alert recipient: look for owner_email in core config, fall back to sender
                let ownerEmail: String? = try? await dbPool.read { db in
                    try String.fetchOne(db, sql: "SELECT content FROM coreBlocks WHERE key = 'owner_email' AND active = 1")
                }
                alertToEmail = ownerEmail ?? inbox.address
                logger.info("Health alerts: from=\(inbox.address), to=\(alertToEmail ?? inbox.address)")
            }
        } catch {
            logger.warning("Could not resolve alert emails: \(error)")
        }
    }

    /// Dedup/throttle gate in front of `deliverAlert`.
    ///
    /// - An alert fires immediately when the condition is NEW or its
    ///   `signature` differs from the last one sent for this check.
    /// - An UNCHANGED condition backs off exponentially from `alertCooldown`,
    ///   capped at `alertMaxInterval`, and its repeat carries a digest
    ///   ("persisted for Xh; N checks suppressed").
    /// `signature` defaults to `message`; health checks pass the count-free
    /// underlying message so the per-cycle failure counter can't defeat dedup.
    private func sendAlert(check: String, message: String, signature: String? = nil) async {
        let sig = Self.normalizedSignature(signature ?? message)
        let now = Date()

        if var state = alertStates[check], state.signature == sig {
            let interval = min(alertMaxInterval, alertCooldown * pow(2, Double(state.sentCount - 1)))
            state.suppressedSinceLast += 1
            if now.timeIntervalSince(state.lastSentAt) < interval {
                alertStates[check] = state   // within backoff window — stay quiet
                return
            }
            let suppressed = state.suppressedSinceLast
            state.lastSentAt = now
            state.sentCount += 1
            state.suppressedSinceLast = 0
            alertStates[check] = state
            let persisted = Self.humanDuration(now.timeIntervalSince(state.firstSentAt))
            let body = """
            \(message)

            (Repeat alert #\(state.sentCount). This condition has persisted for \(persisted); \
            \(suppressed) check(s) suppressed since the last alert. Repeats are throttled and \
            will stop with an all-clear once the check recovers.)
            """
            await deliverAlert(check: check, message: body)
            return
        }

        // New condition (or first failure for this check) — alert now.
        alertStates[check] = AlertState(
            signature: sig, firstSentAt: now, lastSentAt: now, sentCount: 1, suppressedSinceLast: 0
        )
        await deliverAlert(check: check, message: message)
    }

    /// One-shot "recovered" notice when a check that we'd alerted on goes
    /// healthy again. No-op for checks that never crossed the alert threshold.
    private func noteRecovery(check: String) async {
        guard let state = alertStates.removeValue(forKey: check) else { return }
        let persisted = Self.humanDuration(Date().timeIntervalSince(state.firstSentAt))
        await deliverAlert(
            check: check,
            message: "RECOVERED: health check '\(check)' is healthy again after \(persisted) and \(state.sentCount) alert(s)."
        )
    }

    /// Collapse runs of digits/decimal points to a single '#' so a condition's
    /// fingerprint is stable across volatile numbers (free-GB jitter, the
    /// per-cycle failure counter) but still changes when the qualitative
    /// message changes (a different error → re-alert immediately).
    private static func normalizedSignature(_ s: String) -> String {
        var out = ""
        var lastWasNum = false
        for ch in s {
            if ch.isNumber || ch == "." {
                if !lastWasNum { out.append("#"); lastWasNum = true }
            } else {
                out.append(ch); lastWasNum = false
            }
        }
        return out
    }

    /// Compact human duration for alert digests (e.g. "19h 12m", "2d 3h").
    private static func humanDuration(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs))
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    /// Send an alert email via AgentMail HTTP API.
    private func deliverAlert(check: String, message: String) async {
        logger.error("ALERT [\(check)]: \(message)")

        // Resolve sender/recipient from DB on first use
        await resolveAlertEmails()
        guard let fromEmail = alertFromEmail else {
            logger.warning("No email inbox configured — alert logged only")
            return
        }

        // Send via the shared email provider.
        let text = """
        Sonata Health Monitor Alert

        Check: \(check)
        Time: \(ISO8601DateFormatter().string(from: Date()))

        \(message)

        ---
        Sent by Sonata HealthMonitor
        """

        do {
            try await emailProvider.send(
                inbox: fromEmail,
                to: [alertToEmail ?? fromEmail],
                subject: "🚨 Sonata Health Alert: \(check)",
                text: text
            )
            logger.info("Alert email sent for check '\(check)'")
        } catch {
            logger.error("Failed to send alert email: \(error)")
        }
    }

    /// Post a DistributedNotification for other local processes to observe.
    private nonisolated func postDistributedNotification(check: String, message: String) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("sonata.healthAlert"),
            object: check,
            userInfo: ["check": check, "message": message],
            deliverImmediately: true
        )
    }

    // MARK: - Worker nudges

    /// Sweep for "stuck" workers — heartbeating but not making progress on
    /// their current event — and DM them a literal "Continue" so the agent
    /// loop re-engages. No DB state change: the worker drives its own state
    /// machine. The first call after process start acts as the on-boot sweep
    /// (`lastWorkerNudgeAt` starts empty), which is intentional.
    private func nudgeStuckWorkers() async {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let aliveSinceMs = nowMs - Int64(workerHeartbeatFreshness * 1000)
        let stuckBeforeMs = nowMs - Int64(workerStuckThreshold * 1000)

        struct StuckWorker {
            let workerId: String
            let sessionId: String
            let sessionLabel: String
            let currentEventId: String
        }

        let candidates: [StuckWorker]
        do {
            candidates = try await dbPool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT workerId, sessionId, sessionLabel, currentEventId
                        FROM workers
                        WHERE status = 'busy'
                          AND lastHeartbeat >= ?
                          AND currentEventId IS NOT NULL
                          AND currentEventId != ''
                          AND sessionId IS NOT NULL
                          AND sessionId != ''
                          AND (lastProgressAt IS NULL OR lastProgressAt < ?)
                        """,
                    arguments: [aliveSinceMs, stuckBeforeMs]
                ).compactMap { row -> StuckWorker? in
                    guard let workerId = row["workerId"] as? String,
                          let sessionId = row["sessionId"] as? String,
                          let sessionLabel = row["sessionLabel"] as? String,
                          let eventId = row["currentEventId"] as? String else { return nil }
                    return StuckWorker(workerId: workerId, sessionId: sessionId,
                                       sessionLabel: sessionLabel, currentEventId: eventId)
                }
            }
        } catch {
            logger.warning("nudgeStuckWorkers: query failed: \(error)")
            return
        }

        guard !candidates.isEmpty else { return }

        for c in candidates {
            if let last = lastWorkerNudgeAt[c.workerId],
               now.timeIntervalSince(last) < workerNudgeCooldown {
                continue
            }
            lastWorkerNudgeAt[c.workerId] = now
            await sendContinueNudge(to: c.sessionId, workerLabel: c.sessionLabel, eventId: c.currentEventId)
        }
    }

    /// Send a literal "Continue" DM to a worker's session. Persists to the
    /// durable inbox AND tries the live SSE push, matching what the regular
    /// dm_send path does.
    private func sendContinueNudge(to targetSessionId: String, workerLabel: String, eventId: String) async {
        let messageId = UUID().uuidString
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let body = "Continue"
        let context = "health-monitor-nudge:\(eventId)"
        let fromSessionId = "sonata-health-monitor"

        logger.info("nudging stuck worker '\(workerLabel)' (session \(targetSessionId), event \(eventId)) with Continue")

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO dm_messages (
                            messageId, targetSessionId, fromSessionId, fromPubkey, fromPeerId,
                            body, context, metaJson, sentAtMs, receivedAtMs, deliveryStatus
                        ) VALUES (?, ?, ?, NULL, NULL, ?, ?, NULL, ?, ?, 'queued')
                        """,
                    arguments: [messageId, targetSessionId, fromSessionId, body, context, nowMs, nowMs]
                )
            }
        } catch {
            logger.warning("nudgeStuckWorkers: dm_messages insert failed for \(targetSessionId): \(error)")
            return
        }

        let frame = DMFrames.sonarDMNotification(
            messageId: messageId,
            body: body,
            context: context,
            sender: fromSessionId,
            inReplyToMessageId: nil
        )
        _ = await MCPConnections.shared.pushToWorker(identifier: targetSessionId, jsonRPC: frame, dbPool: dbPool)
    }

    /// Reclaim events stranded on a worker that never received them.
    ///
    /// A worker can sit 'busy' with a currentEventId whose SSE push was lost
    /// (MCP disconnect/reconnect, or a cycle in the assign→deliver gap): the
    /// agent never saw the event so never completes it, yet the bridge keeps
    /// heartbeating, so no heartbeat-based sweep ever fires. The discriminator
    /// is `lastProgressAt` — a stranded worker's stops advancing while
    /// `lastHeartbeat` stays fresh.
    ///
    /// `lastProgressAt` is bumped from two paths, both driven by
    /// `workers.currentEventId != NULL`:
    ///   • `MCPSessionSweeper` — every SSE keepalive tick (~15s), for workers
    ///     with a live SSE stream in `MCPConnections`.
    ///   • `worker_heartbeat` (POST /api/worker/heartbeat) — every daemon
    ///     heartbeat, INDEPENDENT of SSE state. This is the fallback for
    ///     brief SSE reconnects mid-tool-call, added 2026-07-06 to close a
    ///     false-positive class (see plan reclaim-stranded-events-fix.md +
    ///     studio card 0d079c2d… in project-sonata/bugs).
    ///
    /// A genuinely-working worker gets `lastProgressAt` bumps from either
    /// path and is never caught here. This fires only for the true stranded
    /// case: worker sits 'busy' with a currentEventId, heartbeats keep coming,
    /// but the agent never received the event so no tool call is running
    /// against it. (Previously this fired ALSO on live workers whose SSE
    /// briefly dropped mid-tool-call — the HTTP-heartbeat auto-bump above
    /// closes that gap.)
    ///
    /// Recovery: re-enqueue the event to 'pending' for another worker and reset
    /// the worker to idle, so the slot self-heals within one monitor cycle
    /// instead of waiting for the 30/75-min supervisor pass. Safe against
    /// double-processing: nobody was working the event, and a later stale
    /// completion from the original worker is rejected by the complete/fail
    /// owner-guard.
    private func reclaimStrandedEvents() async {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let aliveSinceMs = nowMs - Int64(workerHeartbeatFreshness * 1000)
        let stuckBeforeMs = nowMs - Int64(workerStuckThreshold * 1000)

        struct Stranded { let workerId: String; let eventId: String }
        let stranded: [Stranded]
        do {
            stranded = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT w.workerId AS workerId, w.currentEventId AS eventId
                    FROM workers w
                    JOIN workerEvents e ON e.id = w.currentEventId
                    WHERE w.status = 'busy'
                      AND w.lastHeartbeat >= ?
                      AND w.currentEventId IS NOT NULL AND w.currentEventId != ''
                      AND e.status = 'assigned'
                      AND e.assignedAt IS NOT NULL AND e.assignedAt < ?
                      AND (w.lastProgressAt IS NULL OR w.lastProgressAt < ?)
                    """, arguments: [aliveSinceMs, stuckBeforeMs, stuckBeforeMs])
                    .compactMap { row -> Stranded? in
                        guard let wid = row["workerId"] as? String,
                              let eid = row["eventId"] as? String else { return nil }
                        return Stranded(workerId: wid, eventId: eid)
                    }
            }
        } catch {
            logger.warning("reclaimStrandedEvents: query failed: \(error)")
            return
        }

        guard !stranded.isEmpty else { return }

        for s in stranded {
            do {
                try await dbPool.write { db in
                    // Re-enqueue the stranded event for another worker.
                    try db.execute(sql: """
                        UPDATE workerEvents SET status = 'pending', assignedTo = NULL
                        WHERE id = ? AND status = 'assigned'
                    """, arguments: [s.eventId])
                    // Free the worker — but only if it still holds this exact
                    // event and is still busy, so we never clobber a completion
                    // that landed between the read and this write.
                    try db.execute(sql: """
                        UPDATE workers SET status = 'idle',
                            currentEventId = NULL, currentEventTokens = NULL, currentSlug = NULL,
                            currentCacheReadTokens = NULL, currentInputTokens = NULL,
                            currentPromptHash = NULL, currentSessionLabel = NULL,
                            currentCwdBasename = NULL
                        WHERE workerId = ? AND status = 'busy' AND currentEventId = ?
                    """, arguments: [s.workerId, s.eventId])
                }
                logger.info("reclaimStrandedEvents: re-enqueued stranded event \(s.eventId), freed worker \(s.workerId)")
            } catch {
                logger.warning("reclaimStrandedEvents: recovery failed for \(s.workerId): \(error)")
            }
        }
    }

    /// Close sonar_dm workerEvents that have sat `assigned` past `sonarDMTtl`
    /// without a reply, and free the worker holding them.
    ///
    /// Distinct from reclaimStrandedEvents, which RE-ENQUEUES stranded task
    /// events to 'pending' for another worker: a stale DM must be CLOSED, never
    /// requeued — re-dispatching a sonar_dm would deliver the same message to a
    /// second worker and cause crosstalk. A sonar_dm event only stays open to
    /// (a) hold the worker busy while it drafts a reply and (b) let dm_reply's
    /// auto-complete fire. Past the TTL neither happened, so the event is
    /// abandoned; the right move is to close it and release the worker.
    ///
    /// Guard (review, 2026-07-17): never force-close a DM a worker is genuinely
    /// still working. A worker whose `lastHeartbeat` is fresh AND whose
    /// `lastProgressAt` is still advancing is mid-flight (e.g. a slow LLM
    /// reply) — leave its event open until it goes quiet. Only a stranded /
    /// idle / gone worker's DM event is closed. Mirrors reclaimStrandedEvents'
    /// lastProgressAt discriminator.
    private func sweepStaleDMEvents() async {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let ttlBeforeMs = nowMs - Int64(sonarDMTtl * 1000)
        let aliveSinceMs = nowMs - Int64(workerHeartbeatFreshness * 1000)
        let progressStaleBeforeMs = nowMs - Int64(workerStuckThreshold * 1000)

        struct StaleDM { let eventId: String; let workerId: String? }
        let stale: [StaleDM]
        do {
            stale = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id AS eventId, assignedTo AS workerId
                    FROM workerEvents
                    WHERE type = 'sonar_dm'
                      AND status = 'assigned'
                      AND assignedAt IS NOT NULL AND assignedAt < ?
                    LIMIT 200
                    """, arguments: [ttlBeforeMs])
                    .compactMap { row -> StaleDM? in
                        guard let eid = row["eventId"] as? String else { return nil }
                        return StaleDM(eventId: eid, workerId: row["workerId"] as? String)
                    }
            }
        } catch {
            logger.warning("sweepStaleDMEvents: query failed: \(error)")
            return
        }
        guard !stale.isEmpty else { return }

        for s in stale {
            // Skip if a live worker still holds this exact event AND looks
            // genuinely mid-processing (fresh heartbeat + advancing progress).
            if let wid = s.workerId, !wid.isEmpty {
                let stillWorking = (try? await dbPool.read { db -> Bool in
                    (try Int.fetchOne(db, sql: """
                        SELECT 1 FROM workers
                        WHERE workerId = ? AND currentEventId = ? AND status = 'busy'
                          AND lastHeartbeat >= ?
                          AND lastProgressAt IS NOT NULL AND lastProgressAt >= ?
                        """, arguments: [wid, s.eventId, aliveSinceMs, progressStaleBeforeMs])) != nil
                }) ?? false
                if stillWorking { continue }
            }
            do {
                try await dbPool.write { db in
                    try db.execute(sql: """
                        UPDATE workerEvents SET status = 'completed', completedAt = ?,
                            result = 'auto-closed — sonar_dm exceeded TTL with no reply'
                        WHERE id = ? AND status = 'assigned'
                    """, arguments: [nowMs, s.eventId])
                    if let wid = s.workerId, !wid.isEmpty {
                        try db.execute(sql: """
                            UPDATE workers SET status = 'idle',
                                currentEventId = NULL, currentEventTokens = NULL, currentSlug = NULL,
                                currentCacheReadTokens = NULL, currentInputTokens = NULL,
                                currentPromptHash = NULL, currentSessionLabel = NULL,
                                currentCwdBasename = NULL
                            WHERE workerId = ? AND currentEventId = ?
                        """, arguments: [wid, s.eventId])
                    }
                }
                logger.info("sweepStaleDMEvents: closed stale sonar_dm \(s.eventId), freed worker \(s.workerId ?? "-")")
            } catch {
                logger.warning("sweepStaleDMEvents: close failed for \(s.eventId): \(error)")
            }
        }
    }

    /// Row shape used by sweepOrphanedEvents.
    private struct OrphanedEvent {
        let eventId: String
        let type: String
        let taskId: String?
    }

    /// Cancel `assigned` and `pending` events whose `assignedTo` workerId no
    /// longer exists in the workers table (e.g. worker was killed / purged /
    /// displaced by predecessor-cleanup). Un-cancelled orphans accumulate and
    /// get resurrected as "phantom tasks" pinning fresh worker spawns.
    ///
    /// For task-backed orphans, also retry the underlying task (mirrors
    /// reapOfflineWorker's retry policy: pending + retryCount++ if under
    /// maxRetries, else failed with dependent-unblock).
    private func sweepOrphanedEvents() async {
        let now = nowMs()
        let result = "Orphan sweep: assigned worker no longer exists"

        let orphans: [OrphanedEvent]
        do {
            orphans = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, type, payload
                    FROM workerEvents
                    WHERE status IN ('pending', 'assigned')
                      AND assignedTo IS NOT NULL AND assignedTo != ''
                      AND assignedTo NOT IN (SELECT workerId FROM workers)
                    LIMIT 200
                """).compactMap { row -> OrphanedEvent? in
                    guard let id = row["id"] as? String,
                          let type = row["type"] as? String else { return nil }
                    var taskId: String? = nil
                    if let payload = row["payload"] as? String,
                       let data = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        taskId = json["task_id"] as? String
                    }
                    return OrphanedEvent(eventId: id, type: type, taskId: taskId)
                }
            }
        } catch {
            logger.warning("sweepOrphanedEvents: query failed: \(error)")
            return
        }

        guard !orphans.isEmpty else { return }

        struct Tally { var cancelled = 0; var retried = 0; var failed = 0 }
        var tally = Tally()

        for orphan in orphans {
            do {
                let step: Tally = try await dbPool.write { db in
                    var step = Tally()
                    try db.execute(sql: """
                        UPDATE workerEvents
                        SET status = 'cancelled', completedAt = ?, result = ?
                        WHERE id = ? AND status IN ('pending', 'assigned')
                    """, arguments: [now, result, orphan.eventId])
                    guard db.changesCount > 0 else { return step }
                    step.cancelled = 1

                    guard let taskId = orphan.taskId else { return step }

                    let taskRow = try Row.fetchOne(db, sql: """
                        SELECT status, retryCount, COALESCE(maxRetries, 1) AS maxRetries
                        FROM tasks WHERE id = ?
                    """, arguments: [taskId])
                    let currentStatus = taskRow?["status"] as? String
                    let retryCount = taskRow?["retryCount"] as? Int ?? 0
                    let maxRetries = taskRow?["maxRetries"] as? Int ?? 1

                    if currentStatus == "active" && retryCount < maxRetries {
                        try db.execute(sql: """
                            UPDATE tasks SET status = 'pending',
                                             retryCount = retryCount + 1,
                                             startedAt = NULL,
                                             lastError = ?,
                                             updatedAt = ?
                            WHERE id = ? AND status = 'active'
                        """, arguments: ["\(result) — auto-retry", now, taskId])
                        step.retried = 1
                    } else if currentStatus == "active" {
                        try db.execute(sql: """
                            UPDATE tasks SET status = 'failed',
                                             lastError = ?,
                                             updatedAt = ?
                            WHERE id = ? AND status = 'active'
                        """, arguments: ["\(result) — retries exhausted", now, taskId])
                        try unblockDependents(taskId: taskId, in: db, now: now)
                        try rollUpParentStatus(childTaskId: taskId, in: db, now: now)
                        step.failed = 1
                    }
                    return step
                }
                tally.cancelled += step.cancelled
                tally.retried += step.retried
                tally.failed += step.failed
            } catch {
                logger.warning("sweepOrphanedEvents: cleanup failed for event \(orphan.eventId): \(error)")
            }
        }

        if tally.cancelled > 0 {
            logger.warning("sweepOrphanedEvents: cancelled \(tally.cancelled) orphan event(s) (retried \(tally.retried) task(s), failed \(tally.failed))")
        }
    }

    /// Row shape used by escalateOfflineWorkers / reapOfflineWorker.
    private struct OfflineWorkerRow {
        let workerId: String
        let sessionId: String?
        let sessionLabel: String
        let currentEventId: String?
    }

    /// Offline escalation ladder.
    ///
    /// The sweep (`sweepStaleWorkersForActions` in WorkerActions.swift) marks
    /// workers whose HTTP heartbeat has lapsed as `status='offline'` — an
    /// ALERT signal, not a decision. This loop reads that signal and:
    ///
    ///   1. On first sight of an offline worker not yet in escalation:
    ///      send a DM to its session ("you've been flagged offline; heartbeat
    ///      immediately or we cycle you in N minutes"). If the SSE push
    ///      succeeds, start a grace timer. If the SSE push fails, that's a
    ///      second negative liveness signal — skip grace and reap now.
    ///   2. On each subsequent tick while the worker is still offline:
    ///      if the grace deadline has passed, invoke the reap path.
    ///   3. If the worker's DB status transitions out of `offline` (Fix #2
    ///      in worker_heartbeat lets a heartbeat un-stick offline back to
    ///      busy/idle), clear the escalation. False-positive self-healed.
    ///
    /// Reap = cancel the worker's assigned workerEvent, retry-or-fail the
    /// backing task, then hand the workerId to the WorkerManager cycler for
    /// SIGTERM+respawn. Cancelling the event (not re-enqueueing) satisfies
    /// the task-level dupe guard in dispatchToChannel — the fresh redispatch
    /// creates a new event only because no other pending/assigned event
    /// exists for that task_id.
    private func escalateOfflineWorkers() async {
        let now = Date()
        let rows: [OfflineWorkerRow]
        do {
            rows = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT workerId, sessionId, sessionLabel, currentEventId
                    FROM workers
                    WHERE status = 'offline'
                """).compactMap { row -> OfflineWorkerRow? in
                    guard let workerId = row["workerId"] as? String,
                          let sessionLabel = row["sessionLabel"] as? String else { return nil }
                    return OfflineWorkerRow(
                        workerId: workerId,
                        sessionId: row["sessionId"] as? String,
                        sessionLabel: sessionLabel,
                        currentEventId: row["currentEventId"] as? String
                    )
                }
            }
        } catch {
            logger.warning("escalateOfflineWorkers: query failed: \(error)")
            return
        }

        // Clear escalation for workers that recovered out of 'offline'.
        let currentlyOffline = Set(rows.map { $0.workerId })
        for wid in offlineEscalations.keys where !currentlyOffline.contains(wid) {
            logger.info("escalation: worker \(wid) recovered from offline — clearing escalation")
            offlineEscalations.removeValue(forKey: wid)
        }

        for r in rows {
            if let esc = offlineEscalations[r.workerId] {
                // Already escalating — check deadline.
                if now >= esc.deadline {
                    logger.warning("escalation: worker \(r.workerId) still offline past grace — reaping")
                    await reapOfflineWorker(row: r, reason: "no recovery within \(Int(offlineGracePeriod))s grace")
                    offlineEscalations.removeValue(forKey: r.workerId)
                }
                continue
            }

            // Fresh offline transition — DM the worker as a second-signal
            // liveness check.
            let minutes = Int(offlineGracePeriod / 60)
            let body = "You've been flagged offline because your HTTP heartbeat lapsed. "
                + "If you're still alive, call worker_heartbeat immediately to restore your status. "
                + "You have \(minutes) minute\(minutes == 1 ? "" : "s") before we assume you're dead and cycle your process."
            let pushed = await sendOfflineNudge(row: r, body: body)
            if pushed {
                offlineEscalations[r.workerId] = OfflineEscalation(
                    firstOfflineAt: now,
                    dmSentAt: now,
                    deadline: now.addingTimeInterval(offlineGracePeriod)
                )
                logger.info("escalation: DM'd offline worker \(r.workerId) (\(r.sessionLabel)); grace \(Int(offlineGracePeriod))s")
            } else {
                // SSE dead too — two negative liveness signals, no grace.
                logger.warning("escalation: worker \(r.workerId) offline + SSE not live — reaping immediately")
                await reapOfflineWorker(row: r, reason: "offline + SSE not live")
            }
        }
    }

    /// Persist + push the escalation DM to a worker session. The durable
    /// dm_messages row keys by sessionId (dm-subsystem convention). The
    /// live SSE push goes through `pushToWorker`, which accepts either
    /// workerId (the actual MCP session key) or sessionId (via DB
    /// translation) — callers don't need to know the internal keying.
    /// Returns true only if the push landed on a live writer.
    private func sendOfflineNudge(row: OfflineWorkerRow, body: String) async -> Bool {
        guard let targetSessionId = row.sessionId, !targetSessionId.isEmpty else {
            return false
        }
        let messageId = UUID().uuidString
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let context = "health-monitor-offline-escalation:\(row.workerId)"
        let fromSessionId = "sonata-health-monitor"

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO dm_messages (
                            messageId, targetSessionId, fromSessionId, fromPubkey, fromPeerId,
                            body, context, metaJson, sentAtMs, receivedAtMs, deliveryStatus
                        ) VALUES (?, ?, ?, NULL, NULL, ?, ?, NULL, ?, ?, 'queued')
                        """,
                    arguments: [messageId, targetSessionId, fromSessionId, body, context, nowMs, nowMs]
                )
            }
        } catch {
            logger.warning("escalation: dm_messages insert failed for \(targetSessionId): \(error)")
            return false
        }

        let frame = DMFrames.sonarDMNotification(
            messageId: messageId,
            body: body,
            context: context,
            sender: fromSessionId,
            inReplyToMessageId: nil
        )
        return await MCPConnections.shared.pushToWorker(identifier: row.workerId, jsonRPC: frame, dbPool: dbPool)
    }

    /// Reap an offline worker: cancel its assigned event, retry-or-fail the
    /// backing task, then hand the workerId to the WorkerManager cycler for
    /// SIGTERM+respawn. All DB mutations happen in a single transaction so a
    /// concurrent completion can't be clobbered — writes are guarded on the
    /// pre-reap status of each row.
    private func reapOfflineWorker(row: OfflineWorkerRow, reason: String) async {
        let now = nowMs()
        let result = "Offline escalation reap (\(reason))"

        do {
            try await dbPool.write { db in
                guard let eventId = row.currentEventId, !eventId.isEmpty else { return }

                // Discover the backing task (if any) from the event payload.
                var recoveryTaskId: String? = nil
                if let ev = try Row.fetchOne(db,
                    sql: "SELECT payload FROM workerEvents WHERE id = ?",
                    arguments: [eventId]),
                   let payload = ev["payload"] as? String,
                   let data = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    recoveryTaskId = json["task_id"] as? String
                }

                // Cancel the event (not re-enqueue). Cancellation satisfies
                // the task-level dupe guard in dispatchToChannel — a fresh
                // dispatch for the task will succeed because no other
                // pending/assigned event exists for that task_id.
                try db.execute(sql: """
                    UPDATE workerEvents SET status = 'cancelled', completedAt = ?, result = ?
                    WHERE id = ? AND status IN ('pending', 'assigned')
                """, arguments: [now, result, eventId])

                if let taskId = recoveryTaskId {
                    let taskRow = try Row.fetchOne(db, sql: """
                        SELECT status, retryCount, COALESCE(maxRetries, 1) AS maxRetries
                        FROM tasks WHERE id = ?
                    """, arguments: [taskId])
                    let currentStatus = taskRow?["status"] as? String
                    let retryCount = taskRow?["retryCount"] as? Int ?? 0
                    let maxRetries = taskRow?["maxRetries"] as? Int ?? 1

                    if currentStatus == "active" && retryCount < maxRetries {
                        try db.execute(sql: """
                            UPDATE tasks SET status = 'pending',
                                             retryCount = retryCount + 1,
                                             startedAt = NULL,
                                             lastError = ?,
                                             updatedAt = ?
                            WHERE id = ? AND status = 'active'
                        """, arguments: ["\(result) — auto-retry", now, taskId])
                    } else if currentStatus == "active" {
                        try db.execute(sql: """
                            UPDATE tasks SET status = 'failed',
                                             lastError = ?,
                                             updatedAt = ?
                            WHERE id = ? AND status = 'active'
                        """, arguments: ["\(result) — retries exhausted", now, taskId])
                        try unblockDependents(taskId: taskId, in: db, now: now)
                        try rollUpParentStatus(childTaskId: taskId, in: db, now: now)
                    }
                }

                // Clear the worker's current* fields so the cycler sees a
                // clean state to displace.
                try db.execute(sql: """
                    UPDATE workers SET
                        currentEventId = NULL,
                        currentEventTokens = NULL,
                        currentSlug = NULL,
                        currentCacheReadTokens = NULL,
                        currentInputTokens = NULL,
                        currentPromptHash = NULL,
                        currentSessionLabel = NULL,
                        currentCwdBasename = NULL
                    WHERE workerId = ?
                """, arguments: [row.workerId])
            }
        } catch {
            logger.warning("escalation: DB cleanup failed for worker \(row.workerId): \(error)")
        }

        // Hand off to WorkerManager for SIGTERM+respawn. cycleWorkerById is
        // idempotent for workers already in draining/starting/restarting.
        if let cycler = cycleStuckWorkers {
            logger.warning("escalation: cycling worker \(row.workerId) (\(row.sessionLabel))")
            await cycler([row.workerId])
        } else {
            logger.warning("escalation: no cycler available for worker \(row.workerId) — skipping process cycle")
        }
    }

    /// Deterministic wall-clock timeout enforcement for active tasks.
    ///
    /// A task's `metadata.timeoutSeconds` (set e.g. via `--timeout 7200` on a
    /// nightly scout dispatch) is a hard deadline: once the task has been
    /// `active` longer than that, it must be failed. Historically the ONLY
    /// thing enforcing it was a live `/supervisor` LLM session — and
    /// `pushSupervisorCheck()` silently skips when no supervisor has heartbeated
    /// recently, so on nights with no session running the deadline went
    /// unenforced for hours, then a waking session batch-killed the whole
    /// backlog at once with inconsistent, hand-composed error text (2026-07-01:
    /// BKSK / Up Studio / Salas O'Brien each ran 5-6× past their 120-min config,
    /// all killed within 1.5s, message "Exceeded 75-minute timeout" instead of a
    /// timeoutSeconds-aware string).
    ///
    /// This sweep runs every monitor cycle (always on, like reclaimStrandedEvents),
    /// independent of supervisor liveness, and the instant a task crosses its own
    /// deadline it: (1) fails the task with a single consistent message and the
    /// same graph-consistency side effects as `mem_task_fail` (unblockDependents +
    /// rollUpParentStatus + watcher DMs), (2) fails the workerEvent that
    /// dispatched it so the drain re-enqueue guard treats it as terminal, then
    /// (3) hands the assigned worker(s) to `cycleStuckWorkers` for a full
    /// drain+respawn. The transaction deliberately does NOT flip the worker to
    /// 'idle': idling a wedged worker just opens a race window where the
    /// dispatcher hands it a new event that its stuck claude PTY will never
    /// process — the exact regression this reaper is meant to prevent. Leaving
    /// the worker 'busy' with `currentEventId` pointing at the just-failed
    /// event is a safe waypoint until the cycle path swaps it out. The terminal
    /// task UPDATE is guarded on status='active' so a task that finished
    /// between read and write is never clobbered, and any stale completion
    /// from the dying session is rejected by the complete/fail owner-guard.
    /// Tasks without a positive `timeoutSeconds` are never touched.
    private func reapOverdueTasks() async {
        let now = nowMs()

        struct Overdue { let id: String; let title: String; let ranMs: Int64; let timeoutSec: Int64 }
        let overdue: [Overdue]
        do {
            overdue = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, title, startedAt, metadata
                    FROM tasks
                    WHERE status = 'active'
                      AND startedAt IS NOT NULL
                      AND metadata IS NOT NULL
                    """)
                    .compactMap { row -> Overdue? in
                        let id: String? = row["id"]
                        let startedAt: Int64? = row["startedAt"]
                        let metaStr: String? = row["metadata"]
                        guard let id, let startedAt, let metaStr,
                              let metaData = metaStr.data(using: .utf8),
                              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any]
                        else { return nil }
                        // timeoutSeconds may be a JSON number or a numeric string.
                        let timeoutSec: Int64
                        if let n = meta["timeoutSeconds"] as? NSNumber {
                            timeoutSec = n.int64Value
                        } else if let s = meta["timeoutSeconds"] as? String, let v = Int64(s) {
                            timeoutSec = v
                        } else {
                            return nil
                        }
                        guard timeoutSec > 0 else { return nil }
                        let ranMs = now - startedAt
                        guard ranMs > timeoutSec * 1000 else { return nil }
                        let title: String? = row["title"]
                        return Overdue(id: id, title: title ?? id, ranMs: ranMs, timeoutSec: timeoutSec)
                    }
            }
        } catch {
            logger.warning("reapOverdueTasks: query failed: \(error)")
            return
        }

        guard !overdue.isEmpty else { return }

        for t in overdue {
            let ranMin = t.ranMs / 60_000
            let limitMin = t.timeoutSec / 60
            let message = "Exceeded \(limitMin)m timeout (timeoutSeconds:\(t.timeoutSec)) "
                + "— killed by deterministic watchdog after ~\(ranMin)m"
            do {
                struct ReapOutcome { let didFail: Bool; let workerIds: [String] }
                let outcome: ReapOutcome = try await dbPool.write { db in
                    // Fail the task, guarded on status='active' so a completion
                    // that landed between the read and this write is never
                    // clobbered. If nothing changed, skip ALL side effects.
                    try db.execute(sql: """
                        UPDATE tasks SET status = 'failed', lastError = ?, updatedAt = ?
                        WHERE id = ? AND status = 'active'
                        """, arguments: [message, now, t.id])
                    guard db.changesCount > 0 else { return ReapOutcome(didFail: false, workerIds: []) }

                    // Same graph-consistency side effects as mem_task_fail so a
                    // reaper-killed task behaves identically to a hand-failed one.
                    try unblockDependents(taskId: t.id, in: db, now: now)
                    try rollUpParentStatus(childTaskId: t.id, in: db, now: now)

                    // Terminate the dispatch event(s) that carried this task and
                    // collect the worker(s) that were assigned. The task→worker
                    // link is the event payload's `task_id` joined to
                    // workerEvents.assignedTo. We do NOT touch `workers` here —
                    // idling a wedged worker would let the dispatcher hand it a
                    // fresh event while its claude PTY is still stuck. cycle-
                    // Worker handles the state transitions (draining → starting
                    // → idle) via drain+SIGTERM+respawn.
                    let assignedRows = try Row.fetchAll(db, sql: """
                        SELECT id, assignedTo FROM workerEvents
                        WHERE json_extract(payload, '$.task_id') = ?
                          AND status = 'assigned'
                        """, arguments: [t.id])
                    var workerIds: [String] = []
                    for row in assignedRows {
                        guard let eventId: String = row["id"] else { continue }
                        try db.execute(sql: """
                            UPDATE workerEvents SET status = 'failed', result = ?, completedAt = ?
                            WHERE id = ? AND status = 'assigned'
                            """, arguments: [message, now, eventId])
                        if let workerId: String = row["assignedTo"], !workerId.isEmpty {
                            workerIds.append(workerId)
                        }
                    }
                    return ReapOutcome(didFail: true, workerIds: workerIds)
                }
                if outcome.didFail {
                    logger.warning("reapOverdueTasks: failed overdue task \(t.id) '\(t.title)' — \(message)")
                    _ = await fireTaskWatcherDMs(
                        taskId: t.id, oldStatus: "active", newStatus: "failed", dbPool: dbPool
                    )
                    if !outcome.workerIds.isEmpty, let cycler = cycleStuckWorkers {
                        let joined = outcome.workerIds.joined(separator: ",")
                        logger.warning("reapOverdueTasks: cycling \(outcome.workerIds.count) worker(s) that held task \(t.id): \(joined)")
                        await cycler(outcome.workerIds)
                    }
                }
            } catch {
                logger.warning("reapOverdueTasks: fail write failed for \(t.id): \(error)")
            }
        }
    }

    /// Test-only invoker for the deterministic timeout reaper (private otherwise).
    func reapOverdueTasksForTesting() async {
        await reapOverdueTasks()
    }
}
