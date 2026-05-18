import Foundation
import GRDB
import SQLite3

// Sonar DMs v0 — Sonata-side routing.
//
// Mirrors AFKActions.swift / AFKRegistry pattern for session-addressed direct
// messages that arrive over the Sonar plugin's `messages:events / new_message`
// channel. The bridge polls /api/dm/poll and pushes each envelope into the
// session via `notifications/claude/channel` with `meta.event_type=sonar_dm`.
//
// Persistence: every inbound DM lands in `dm_messages` BEFORE the in-memory
// DMRegistry enqueue, so a bridge that registers after the fact can backfill
// via /api/dm/inbox.
//
// Plan: /Users/evan/memory/claude/documents/plans/sonar-dm-v0-plan.md
// Sections: §4 (Sonata-side endpoints), §6 (MCP types), §7 (error policy),
// §11 (locked decisions), §12 (security findings A.1, A.7), §13 (limits).

// MARK: - Types

struct DMRegistration: Codable, Sendable {
    let sessionId: String
    let sessionLabel: String?
    let role: String?           // "orchestrator" | "worker" | "interactive" | caller-supplied
    let registeredAt: Int64
}

struct DMEnvelope: Codable, Sendable {
    let messageId: String        // Sonar message id (16-byte hex) or local UUID
    let fromSessionId: String?   // claimed by sender — NOT verified for federated
    let fromPubkey: String?      // verified peer instance_id (federation only)
    let fromPeerId: String?      // local peers.id (sender side); nil for inbound on receiver
    let targetSessionId: String
    let body: String
    let context: String?
    let sentAtMs: Int64          // sender wall clock
    let receivedAtMs: Int64      // Sonata wall clock on inbound
    let metaJson: String?        // optional caller-supplied JSON blob, ≤ 4 KB
}

// MARK: - Limits & validation

enum DMLimits {
    static let bodyMaxBytes = 256 * 1024
    static let metaMaxBytes = 4 * 1024
    static let perTargetCap = 100
    static let seenLruCap = 256
    /// Heartbeat freshness window. Cross-references workers.lastHeartbeat AND
    /// ExternalBridgeRegistry.entries[].lastHeartbeat. Pass A.7: also enforced
    /// at enqueue time so a stale registration that pre-dates the prune cycle
    /// can't smuggle a delivery in.
    static let heartbeatStaleAfterMs: Int64 = 120_000
    static let pruneIntervalSeconds: TimeInterval = 60
    static let sessionIdRegex = #"^[A-Za-z0-9_-]{1,128}$"#
}

private func isValidSessionId(_ s: String) -> Bool {
    s.range(of: DMLimits.sessionIdRegex, options: .regularExpression) != nil
}

// MARK: - Per-session LRU of seen messageIds

/// Tiny LRU keyed on Sonar messageId so a relay double-deliver or HTTP-retry
/// is dropped at the registry boundary in addition to the dm_messages
/// `INSERT OR IGNORE` belt. Capacity 256 per session.
struct SeenMessageRing {
    private var order: [String] = []
    private var set: Set<String> = []
    let capacity: Int

    init(capacity: Int = DMLimits.seenLruCap) { self.capacity = capacity }

    /// Insert; returns true if the id was already present (i.e. a duplicate).
    @discardableResult
    mutating func insert(_ id: String) -> Bool {
        if set.contains(id) { return true }
        order.append(id)
        set.insert(id)
        if order.count > capacity {
            let oldest = order.removeFirst()
            set.remove(oldest)
        }
        return false
    }

    func contains(_ id: String) -> Bool { set.contains(id) }
}

// MARK: - Heartbeat checker (Sendable closure injected for test isolation)

/// Returns true iff `sessionId` has a fresh heartbeat. In production this
/// queries the `workers` table AND `ExternalBridgeRegistry.shared`. Tests
/// inject a synchronous override (no DB, no actor hop).
struct DMHeartbeatChecker: Sendable {
    let isFresh: @Sendable (_ sessionId: String) async -> Bool
}

// MARK: - DMRegistry

/// In-memory registry. NSLock-protected (mirrors AFKRegistry).
final class DMRegistry: @unchecked Sendable {
    static let shared = DMRegistry()

    private let lock = NSLock()
    private var registrations: [String: DMRegistration] = [:]
    private var pendingDeliveries: [String: [DMEnvelope]] = [:]
    private var seenMessageIds: [String: SeenMessageRing] = [:]
    private var pruneTask: Task<Void, Never>?

    /// Set in production by SonataApp at startup. Tests construct a checker
    /// inline. Nil checker means "always fresh" — useful for tests that don't
    /// exercise pruning, but production must set this.
    private var heartbeatChecker: DMHeartbeatChecker?

    /// Logger callback for overflow warnings; default writes to sonataFileLog.
    private let warn: @Sendable (String) -> Void

    init(warn: @escaping @Sendable (String) -> Void = defaultWarn) {
        self.warn = warn
    }

    // MARK: registration

    /// Register a session as a DM target. Idempotent (overwrites existing).
    /// Pass A.1 caller-side gating happens in the HTTP handler before this.
    func register(sessionId: String, sessionLabel: String?, role: String?) {
        lock.lock(); defer { lock.unlock() }
        registrations[sessionId] = DMRegistration(
            sessionId: sessionId,
            sessionLabel: sessionLabel,
            role: role,
            registeredAt: nowMsValue()
        )
    }

    /// Idempotent — silently no-ops if absent. Clears pending queue + LRU.
    func unregister(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        registrations.removeValue(forKey: sessionId)
        pendingDeliveries.removeValue(forKey: sessionId)
        seenMessageIds.removeValue(forKey: sessionId)
    }

    func has(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registrations[sessionId] != nil
    }

    /// Snapshot of current registrations, oldest-first.
    func listRegistrations() -> [DMRegistration] {
        lock.lock(); defer { lock.unlock() }
        return registrations.values.sorted { $0.registeredAt < $1.registeredAt }
    }

    // MARK: delivery

    /// Enqueue a DM for the target. Returns true if a registration exists and
    /// the envelope was queued; false otherwise (caller should still persist
    /// to `dm_messages` for inbox backfill).
    @discardableResult
    func enqueue(_ envelope: DMEnvelope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let sid = envelope.targetSessionId
        guard registrations[sid] != nil else { return false }

        // De-dup at registry boundary (Pass A.3 + Pass C round). Returning
        // true here would be a lie — the envelope is intentionally dropped
        // because we already enqueued it once for this session.
        var ring = seenMessageIds[sid] ?? SeenMessageRing()
        if ring.insert(envelope.messageId) {
            seenMessageIds[sid] = ring
            return true
        }
        seenMessageIds[sid] = ring

        var queue = pendingDeliveries[sid] ?? []
        queue.append(envelope)
        if queue.count > DMLimits.perTargetCap {
            let dropped = queue.removeFirst()
            warn("dm_overflow: target=\(sid) dropped messageId=\(dropped.messageId) (queue exceeded \(DMLimits.perTargetCap))")
        }
        pendingDeliveries[sid] = queue
        return true
    }

    /// Drain pending deliveries for a session. Bridge calls this on each poll.
    func claimReplies(sessionId: String) -> [DMEnvelope] {
        lock.lock(); defer { lock.unlock() }
        let queue = pendingDeliveries[sessionId] ?? []
        pendingDeliveries[sessionId] = nil
        return queue
    }

    // MARK: heartbeat freshness gate (Pass A.7)

    func setHeartbeatChecker(_ checker: DMHeartbeatChecker?) {
        lock.lock(); defer { lock.unlock() }
        heartbeatChecker = checker
    }

    /// Snapshot the current heartbeat checker (so callers can run it without
    /// holding the registry lock during the async hop).
    func currentHeartbeatChecker() -> DMHeartbeatChecker? {
        lock.lock(); defer { lock.unlock() }
        return heartbeatChecker
    }

    // MARK: prune timer

    /// Start the 60s prune Timer. Cross-references workers + ExternalBridgeRegistry
    /// heartbeats; entries with no heartbeat in >120s are unregistered + queues
    /// cleared. Belt-and-braces: also prunes orphan queues whose sessionId has
    /// no active registration AND no heartbeat anywhere.
    func startPruneTimer() {
        if pruneTask != nil { return }
        pruneTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DMLimits.pruneIntervalSeconds))
                if Task.isCancelled { return }
                await self?.runPruneOnce()
            }
        }
    }

    func stopPruneTimer() {
        pruneTask?.cancel()
        pruneTask = nil
    }

    /// Single prune pass. Exposed for tests so they can drive it without the timer.
    func runPruneOnce() async {
        let checker = currentHeartbeatChecker()
        guard let checker else { return }
        let snapshot = withLock { () -> [String] in
            // Union of registrations + orphan queue keys.
            var all = Set(registrations.keys)
            all.formUnion(pendingDeliveries.keys)
            return Array(all)
        }
        var stale: [String] = []
        for sid in snapshot {
            if !(await checker.isFresh(sid)) { stale.append(sid) }
        }
        if stale.isEmpty { return }
        withLock { () -> Void in
            for sid in stale {
                registrations.removeValue(forKey: sid)
                pendingDeliveries.removeValue(forKey: sid)
                seenMessageIds.removeValue(forKey: sid)
            }
        }
    }

    /// Synchronous lock helper — same pattern as PluginManager.withLock. Needed
    /// because NSLock.lock/unlock are unavailable from async contexts under
    /// Swift 6 language mode.
    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: test seams

    /// Test-only: drop all in-memory state. Production code never calls this.
    func _resetForTests() {
        lock.lock(); defer { lock.unlock() }
        registrations.removeAll()
        pendingDeliveries.removeAll()
        seenMessageIds.removeAll()
    }

    /// Test-only: peek at the queued envelopes for a session without draining.
    func _peekQueue(sessionId: String) -> [DMEnvelope] {
        lock.lock(); defer { lock.unlock() }
        return pendingDeliveries[sessionId] ?? []
    }

    /// Test-only: peek at the seen-LRU ring for a session.
    func _peekSeenRing(sessionId: String) -> SeenMessageRing? {
        lock.lock(); defer { lock.unlock() }
        return seenMessageIds[sessionId]
    }
}

@Sendable private func defaultWarn(_ msg: String) {
    // sonataFileLog is the project-wide logger. Keep this tiny so tests can
    // override without pulling in the file system.
    sonataFileLog(msg)
}

private func nowMsValue() -> Int64 { nowMs() }

// MARK: - Persistence

/// INSERT OR IGNORE on messageId (replay de-dup belt #2). Returns true iff
/// a row was newly inserted (changes() == 1).
@discardableResult
func dmMessagesPersist(_ env: DMEnvelope, deliveryStatus: String, db: Database) throws -> Bool {
    let before = db.changesCount
    try db.execute(sql: """
        INSERT OR IGNORE INTO dm_messages (
            messageId, targetSessionId, fromSessionId, fromPubkey, fromPeerId,
            body, context, metaJson, sentAtMs, receivedAtMs, deliveryStatus
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, arguments: [
        env.messageId, env.targetSessionId, env.fromSessionId, env.fromPubkey, env.fromPeerId,
        env.body, env.context, env.metaJson, env.sentAtMs, env.receivedAtMs, deliveryStatus,
    ])
    return db.changesCount > before
}

private extension Database {
    var changesCount: Int { Int(sqlite3_changes(sqliteConnection)) }
}

// MARK: - DMActions namespace (inbound dispatcher)

enum DMActions {
    /// Inbound DM dispatcher. Called by PluginManager.handlePluginEvent for
    /// "new_message" payloads whose `target_session_id` is non-empty. Persists
    /// the dm_messages row FIRST (so backfill survives even if enqueue fails),
    /// then attempts in-memory enqueue. Idempotent on messageId.
    static func routeInbound(
        payload: [String: Any],
        dbPool: DatabasePool,
        registry: DMRegistry = .shared,
        nowFn: () -> Int64 = nowMs
    ) async {
        guard let target = (payload["target_session_id"] as? String), !target.isEmpty else { return }
        let messageId = (payload["message_id"] as? String) ?? newUUID()
        let fromSessionId = payload["from_session_id"] as? String
        let fromPubkey = payload["from_peer"] as? String
        let body = (payload["question"] as? String) ?? ""
        let context = payload["context"] as? String
        let metaJson = payload["meta_json"] as? String
        // Sender wall clock is best-effort; if missing, fall back to receivedAt.
        let now = nowFn()
        let sentAt = (payload["sent_at_ms"] as? Int64) ?? (payload["sent_at_ms"] as? Int).map(Int64.init) ?? now
        let env = DMEnvelope(
            messageId: messageId,
            fromSessionId: fromSessionId,
            fromPubkey: fromPubkey,
            fromPeerId: nil,
            targetSessionId: target,
            body: body,
            context: context,
            sentAtMs: sentAt,
            receivedAtMs: now,
            metaJson: metaJson
        )
        do {
            try await dbPool.write { db in
                _ = try dmMessagesPersist(env, deliveryStatus: "queued", db: db)
            }
        } catch {
            sonataFileLog("DMActions.routeInbound: persist failed messageId=\(messageId) — \(error)")
        }
        let routed = registry.enqueue(env)
        if !routed {
            sonataFileLog("DMActions.routeInbound: target=\(target) unregistered; persisted only")
        }
    }
}

// MARK: - HTTP responses

private struct DMRegisterResponse: Encodable {
    let ok: Bool
    let sessionId: String
}

private struct DMPollResponse: Encodable {
    let messages: [DMEnvelope]
}

private struct DMSendResponse: Encodable {
    let messageId: String
    let queuedAtMs: Int64
    let deliveryStatus: String
}

private struct DMInboxResponse: Encodable {
    let messages: [DMEnvelope]
}

private struct DMRegistryResponse: Encodable {
    let entries: [DMRegistration]
    let generatedAt: Int64
}

// MARK: - Helpers shared by /send routing

/// Produce a heartbeat checker that consults workers + MCPSessionRegistry.
/// In-app MCP sessions count as "fresh" when their SSE writer is attached;
/// the worker pool falls back to the lastHeartbeat column in the workers
/// table (refreshed by MCPSessionSweeper).
func makeProductionHeartbeatChecker(dbPool: DatabasePool) -> DMHeartbeatChecker {
    DMHeartbeatChecker(isFresh: { sessionId in
        let cutoff = nowMs() - DMLimits.heartbeatStaleAfterMs
        // MCP sessions first — SSE attach is the presence proof.
        if let reg = MCPSessionRegistry.shared {
            let snaps = await reg.snapshot()
            if snaps.contains(where: { $0.sessionKey == sessionId && $0.hasSSE }) {
                return true
            }
        }
        // Fall through to workers table.
        do {
            let row = try await dbPool.read { db -> Int64? in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT lastHeartbeat FROM workers WHERE sessionId = ? OR workerId = ? LIMIT 1",
                    arguments: [sessionId, sessionId]
                )
            }
            if let hb = row, hb >= cutoff { return true }
        } catch {
            // Treat DB errors as "not fresh" — the safe direction.
        }
        return false
    })
}

/// 7-day TTL cleanup. Hooked into nightly maintenance (BackupManager).
@discardableResult
func dmMessagesCleanupOld(dbPool: DatabasePool, ttlMs: Int64 = 7 * 24 * 60 * 60 * 1000) async -> Int {
    let cutoff = nowMs() - ttlMs
    do {
        return try await dbPool.write { db -> Int in
            try db.execute(
                sql: "DELETE FROM dm_messages WHERE deliveredAtMs IS NOT NULL AND deliveredAtMs < ?",
                arguments: [cutoff]
            )
            return Int(sqlite3_changes(db.sqliteConnection))
        }
    } catch {
        sonataFileLog("dmMessagesCleanupOld: \(error)")
        return 0
    }
}

// MARK: - Endpoints

let dmActions: [SonataAction] = [

    // POST /api/dm/register — Pass A.1: reject sessionIds without a fresh
    // heartbeat in workers OR ExternalBridgeRegistry.
    SonataAction(
        name: "dm_register",
        description: "Register a session as a Sonar DM target. Bridge must already have a fresh heartbeat in workers or ExternalBridgeRegistry. Idempotent.",
        group: "/api/dm",
        path: "/register",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Bridge session id (regex: [A-Za-z0-9_-]{1,128})"),
            ActionParam("sessionLabel", .string, required: false, description: "Optional friendly label"),
            ActionParam("role", .string, required: false, description: "Optional role hint: orchestrator | worker | interactive"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            guard isValidSessionId(sessionId) else {
                throw ActionError.custom("bad_session_id: \(sessionId)", .unprocessableContent)
            }
            // Pass A.1: reject unless this bridge has registered itself in
            // workers/external_bridges first. Cheap check that closes the
            // "any process on localhost can register an arbitrary id" hole.
            let checker = makeProductionHeartbeatChecker(dbPool: ctx.dbPool)
            DMRegistry.shared.setHeartbeatChecker(checker)
            let fresh = await checker.isFresh(sessionId)
            guard fresh else {
                throw ActionError.custom("bad_session_id: no fresh heartbeat for \(sessionId)", .unprocessableContent)
            }
            DMRegistry.shared.register(
                sessionId: sessionId,
                sessionLabel: ctx.params.string("sessionLabel"),
                role: ctx.params.string("role")
            )
            return DMRegisterResponse(ok: true, sessionId: sessionId)
        }
    ),

    // POST /api/dm/unregister — idempotent (200 even if absent).
    SonataAction(
        name: "dm_unregister",
        description: "Remove a session from the DM registry. Pending queue is cleared. Idempotent.",
        group: "/api/dm",
        path: "/unregister",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Bridge session id"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            DMRegistry.shared.unregister(sessionId: sessionId)
            return SuccessResponse()
        }
    ),

    // GET /api/dm/poll?sessionId=<id> — drain pending deliveries.
    SonataAction(
        name: "dm_poll",
        description: "Drain pending DMs for a session. Bridge calls this on each poll cycle.",
        group: "/api/dm",
        path: "/poll",
        method: .get,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Bridge session id", source: .query),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            guard isValidSessionId(sessionId) else {
                throw ActionError.custom("bad_session_id: \(sessionId)", .unprocessableContent)
            }
            let messages = DMRegistry.shared.claimReplies(sessionId: sessionId)
            // Mark delivered in dm_messages so the 7-day TTL clock starts ticking.
            if !messages.isEmpty {
                let now = nowMs()
                let ids = messages.map(\.messageId)
                do {
                    try await ctx.dbPool.write { db in
                        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                        try db.execute(
                            sql: "UPDATE dm_messages SET deliveryStatus = 'delivered', deliveredAtMs = ? WHERE messageId IN (\(placeholders))",
                            arguments: StatementArguments([now] + ids)
                        )
                    }
                } catch {
                    sonataFileLog("dm_poll: deliveredAt update failed — \(error)")
                }
            }
            return DMPollResponse(messages: messages)
        }
    ),

    // POST /api/dm/send — local loopback or peer-forwarded send.
    SonataAction(
        name: "dm_send",
        description: "Send a session-addressed DM. Local: omit peerId. Remote: include peerId (Sonar peers.id).",
        group: "/api/dm",
        path: "/send",
        method: .post,
        params: [
            ActionParam("targetSessionId", .string, required: true, description: "Target bridge session id"),
            ActionParam("fromSessionId", .string, required: true, description: "Sender bridge session id"),
            ActionParam("body", .string, required: true, description: "Message body, ≤ 256 KB"),
            ActionParam("peerId", .string, required: false, description: "Sonar peers.id for remote target; omit for local loopback"),
            ActionParam("context", .string, required: false, description: "Optional context"),
            ActionParam("meta", .object, required: false, description: "Optional ≤4KB JSON metadata blob"),
        ],
        handler: { ctx in
            let targetSessionId = try ctx.params.require("targetSessionId")
            let fromSessionId = try ctx.params.require("fromSessionId")
            let body = try ctx.params.require("body")
            let peerId = ctx.params.string("peerId").flatMap { $0.isEmpty ? nil : $0 }
            let context = ctx.params.string("context")
            let metaObj = ctx.params.object("meta")

            // Validation matrix per plan §7 + Pass E.7 (empty body).
            guard isValidSessionId(targetSessionId) else {
                throw ActionError.custom("bad_session_id: \(targetSessionId)", .unprocessableContent)
            }
            guard isValidSessionId(fromSessionId) else {
                throw ActionError.custom("bad_session_id: \(fromSessionId)", .unprocessableContent)
            }
            guard !body.isEmpty else {
                throw ActionError.custom("body_empty", .unprocessableContent)
            }
            guard body.utf8.count <= DMLimits.bodyMaxBytes else {
                throw ActionError.custom("body_too_large", .unprocessableContent)
            }
            var metaJson: String? = nil
            if let metaObj {
                let data = try JSONSerialization.data(withJSONObject: metaObj, options: [.sortedKeys])
                guard data.count <= DMLimits.metaMaxBytes else {
                    throw ActionError.custom("meta_too_large", .unprocessableContent)
                }
                metaJson = String(data: data, encoding: .utf8)
            }

            let now = nowMs()
            let messageId = newUUID()

            if let peerId {
                // Forward via Sonar plugin (capability-gated per §11.5).
                let cardCheck = await fetchAndCheckSonarPeerCapability(peerId: peerId)
                switch cardCheck {
                case .ok:
                    break
                case .missing:
                    throw ActionError.custom("peer_capability_missing: peer \(peerId) does not advertise dm_v1", .serviceUnavailable)
                case .error(let msg):
                    throw ActionError.custom("peer_send_failed: peer card lookup — \(msg)", .badGateway)
                }

                let sendResult = await sonarSendForward(
                    peerId: peerId,
                    body: body,
                    context: context,
                    targetSessionId: targetSessionId,
                    fromSessionId: fromSessionId
                )
                switch sendResult {
                case .ok(let remoteMessageId):
                    let env = DMEnvelope(
                        messageId: remoteMessageId ?? messageId,
                        fromSessionId: fromSessionId,
                        fromPubkey: nil,
                        fromPeerId: peerId,
                        targetSessionId: targetSessionId,
                        body: body,
                        context: context,
                        sentAtMs: now,
                        receivedAtMs: now,
                        metaJson: metaJson
                    )
                    try? await ctx.dbPool.write { db in
                        _ = try dmMessagesPersist(env, deliveryStatus: "queued", db: db)
                    }
                    return DMSendResponse(messageId: env.messageId, queuedAtMs: now, deliveryStatus: "queued")
                case .failed(let msg):
                    throw ActionError.custom("peer_send_failed: \(msg)", .badGateway)
                }
            }

            // Local loopback. Presence = MCPSessionRegistry.hasSSE on the
            // target sessionKey. Persist FIRST (so the recipient can backfill
            // via dm_inbox even if the SSE attach drops mid-push), then push
            // via the in-app MCPNotificationDispatcher / Registry.deliverDM
            // path. The legacy DMRegistry enqueue-and-poll surface is dead
            // (no bridge polls it).
            let env = DMEnvelope(
                messageId: messageId,
                fromSessionId: fromSessionId,
                fromPubkey: nil,
                fromPeerId: nil,
                targetSessionId: targetSessionId,
                body: body,
                context: context,
                sentAtMs: now,
                receivedAtMs: now,
                metaJson: metaJson
            )

            if let mcpReg = MCPSessionRegistry.shared {
                let delivered = await mcpReg.deliverDM(
                    target: targetSessionId,
                    messageId: messageId,
                    body: body,
                    fromSessionId: fromSessionId,
                    context: context,
                    metaJson: metaJson,
                    sentAtMs: now
                )
                if delivered {
                    try? await ctx.dbPool.write { db in
                        _ = try dmMessagesPersist(env, deliveryStatus: "queued", db: db)
                    }
                    return DMSendResponse(messageId: messageId, queuedAtMs: now, deliveryStatus: "queued")
                }
            }

            // §11.1 lazy-optimistic: 202 if a recent dm_messages row exists for
            // this target (within 24h), otherwise strict 404.
            let recentExists = (try? await ctx.dbPool.read { db -> Bool in
                let cutoff = now - 24 * 60 * 60 * 1000
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM dm_messages WHERE targetSessionId = ? AND receivedAtMs >= ?",
                    arguments: [targetSessionId, cutoff]
                ) ?? 0
                return count > 0
            }) ?? false

            if recentExists {
                try? await ctx.dbPool.write { db in
                    _ = try dmMessagesPersist(env, deliveryStatus: "queued_unregistered", db: db)
                }
                return DMSendResponse(messageId: messageId, queuedAtMs: now, deliveryStatus: "queued_unregistered")
            }
            throw ActionError.custom("target_session_unknown: \(targetSessionId)", .notFound)
        }
    ),

    // GET /api/dm/inbox?sessionId&since&limit — durable backfill (NOT drained).
    SonataAction(
        name: "dm_inbox",
        description: "Backfill: durable DM rows addressed to a session, ordered receivedAtMs ASC. NOT drained.",
        group: "/api/dm",
        path: "/inbox",
        method: .get,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Bridge session id", source: .query),
            ActionParam("since", .integer, required: false, description: "Min receivedAtMs (epoch ms); default 0", source: .query),
            ActionParam("limit", .integer, required: false, description: "Max rows (default 50, max 500)", source: .query),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            guard isValidSessionId(sessionId) else {
                throw ActionError.custom("bad_session_id: \(sessionId)", .unprocessableContent)
            }
            let since = Int64(ctx.params.int("since") ?? 0)
            let limit = max(1, min(ctx.params.int("limit") ?? 50, 500))
            let rows = try await ctx.dbPool.read { db -> [DMEnvelope] in
                let stmt = try db.makeStatement(sql: """
                    SELECT messageId, targetSessionId, fromSessionId, fromPubkey, fromPeerId,
                           body, context, metaJson, sentAtMs, receivedAtMs
                    FROM dm_messages
                    WHERE targetSessionId = ? AND receivedAtMs >= ?
                    ORDER BY receivedAtMs ASC
                    LIMIT ?
                """)
                let cursor = try Row.fetchCursor(stmt, arguments: [sessionId, since, limit])
                var out: [DMEnvelope] = []
                while let r = try cursor.next() {
                    out.append(DMEnvelope(
                        messageId: r["messageId"],
                        fromSessionId: r["fromSessionId"],
                        fromPubkey: r["fromPubkey"],
                        fromPeerId: r["fromPeerId"],
                        targetSessionId: r["targetSessionId"],
                        body: r["body"],
                        context: r["context"],
                        sentAtMs: r["sentAtMs"],
                        receivedAtMs: r["receivedAtMs"],
                        metaJson: r["metaJson"]
                    ))
                }
                return out
            }
            return DMInboxResponse(messages: rows)
        }
    ),

    // GET /api/dm/registry — public snapshot (used by Sonar's sonar_session_list).
    SonataAction(
        name: "dm_registry",
        description: "Snapshot of currently-registered DM sessions. Used by Sonar's sonar_session_list.",
        group: "/api/dm",
        path: "/registry",
        method: .get,
        params: [],
        handler: { _ in
            DMRegistryResponse(
                entries: DMRegistry.shared.listRegistrations(),
                generatedAt: nowMs()
            )
        }
    ),

    // POST /api/dm/broadcast — DMAll. Fan a single DM to every
    // SSE-attached session matching the optional kind filter. Used by
    // the dashboard "Broadcast" affordance and the sonar_dm_broadcast
    // MCP tool (the MCP tool routes through MCPToolHandlers; the HTTP
    // route lets non-MCP callers — dashboard, scripts — do the same
    // thing).
    SonataAction(
        name: "dm_broadcast",
        description: "Send a DM to every SSE-attached session matching the optional kind filter ('all'|'workers'|'interactive'|'supervisor'; default 'all'). Excludes the sender.",
        group: "/api/dm",
        path: "/broadcast",
        method: .post,
        params: [
            ActionParam("fromSessionId", .string, required: true, description: "Sender session id"),
            ActionParam("body", .string, required: true, description: "Message body, ≤ 256 KB"),
            ActionParam("filter", .string, required: false, description: "Recipient kind filter (default 'all')"),
            ActionParam("context", .string, required: false, description: "Optional context string"),
        ],
        handler: { ctx in
            let fromSessionId = try ctx.params.require("fromSessionId")
            let body = try ctx.params.require("body")
            let filterRaw = (ctx.params.string("filter") ?? "all").lowercased()
            let context = ctx.params.string("context")
            guard !body.isEmpty else {
                throw ActionError.custom("body required", .unprocessableContent)
            }
            guard body.utf8.count <= 256 * 1024 else {
                throw ActionError.custom("body exceeds 256 KiB", .unprocessableContent)
            }
            let allow: (SessionRole) -> Bool
            switch filterRaw {
            case "worker", "workers": allow = { $0 == .worker }
            case "interactive", "humans": allow = { $0 == .interactive }
            case "supervisor": allow = { $0 == .supervisor }
            case "all", "": allow = { _ in true }
            default:
                throw ActionError.custom("unknown filter '\(filterRaw)'", .unprocessableContent)
            }
            guard let reg = MCPSessionRegistry.shared else {
                return DMBroadcastResponse(
                    filter: filterRaw, deliveredCount: 0, skippedCount: 0,
                    deliveredTo: [])
            }
            let snaps = await reg.snapshot()
            var delivered: [String] = []
            var skipped = 0
            let now = nowMs()
            for snap in snaps {
                guard allow(snap.role), snap.hasSSE,
                      snap.sessionKey != fromSessionId else {
                    skipped += 1; continue
                }
                let messageId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
                let pushed = await reg.deliverDM(
                    target: snap.sessionKey,
                    messageId: messageId,
                    body: body,
                    fromSessionId: fromSessionId,
                    context: context,
                    metaJson: nil,
                    sentAtMs: now
                )
                if pushed {
                    delivered.append(snap.sessionKey)
                    let env = DMEnvelope(
                        messageId: messageId,
                        fromSessionId: fromSessionId,
                        fromPubkey: nil,
                        fromPeerId: nil,
                        targetSessionId: snap.sessionKey,
                        body: body,
                        context: context,
                        sentAtMs: now,
                        receivedAtMs: now,
                        metaJson: nil
                    )
                    try? await ctx.dbPool.write { db in
                        _ = try dmMessagesPersist(env, deliveryStatus: "queued", db: db)
                    }
                } else {
                    skipped += 1
                }
            }
            return DMBroadcastResponse(
                filter: filterRaw,
                deliveredCount: delivered.count,
                skippedCount: skipped,
                deliveredTo: delivered
            )
        }
    ),
]

private struct DMBroadcastResponse: Encodable {
    let filter: String
    let deliveredCount: Int
    let skippedCount: Int
    let deliveredTo: [String]

    enum CodingKeys: String, CodingKey {
        case filter
        case deliveredCount = "delivered_count"
        case skippedCount = "skipped_count"
        case deliveredTo = "delivered_to"
    }
}

// MARK: - Sonar peer-card + send wiring

private enum SonarPeerCapability { case ok, missing, error(String) }
private enum SonarSendOutcome { case ok(remoteMessageId: String?); case failed(String) }

private actor SonarPeerCardCache {
    static let shared = SonarPeerCardCache()
    private var byPeerId: [String: (capability: SonarPeerCapability, fetchedAtMs: Int64)] = [:]
    private let ttlMs: Int64 = 5 * 60 * 1000  // §11.5 — 5 min cache

    func get(_ peerId: String) -> SonarPeerCapability? {
        guard let entry = byPeerId[peerId] else { return nil }
        if nowMs() - entry.fetchedAtMs > ttlMs { return nil }
        return entry.capability
    }

    func set(_ peerId: String, _ cap: SonarPeerCapability) {
        byPeerId[peerId] = (cap, nowMs())
    }
}

private func fetchAndCheckSonarPeerCapability(peerId: String) async -> SonarPeerCapability {
    if let cached = await SonarPeerCardCache.shared.get(peerId) { return cached }
    // Sonar exposes peer_card.json over loopback at /api/peers/<id>/card. Plan §3.5
    // names "/.well-known/sonar/card.json" — that's the *remote* peer's surface.
    // Locally we ask Sonar to fetch it for us via /api/peers/<id>/card.
    let urlStr = "http://127.0.0.1:4000/api/peers/\(peerId)/card"
    guard let url = URL(string: urlStr) else {
        return .error("invalid peer card URL")
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 5
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            let result: SonarPeerCapability = .error("non-HTTP response from Sonar peer card lookup")
            await SonarPeerCardCache.shared.set(peerId, result)
            return result
        }
        if http.statusCode == 404 {
            let result: SonarPeerCapability = .error("peer not found")
            await SonarPeerCardCache.shared.set(peerId, result)
            return result
        }
        guard (200..<300).contains(http.statusCode) else {
            let result: SonarPeerCapability = .error("HTTP \(http.statusCode)")
            await SonarPeerCardCache.shared.set(peerId, result)
            return result
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let caps = (json["capabilities"] as? [String]) ?? []
        let cap: SonarPeerCapability = caps.contains("dm_v1") ? .ok : .missing
        await SonarPeerCardCache.shared.set(peerId, cap)
        return cap
    } catch {
        return .error(error.localizedDescription)
    }
}

private func sonarSendForward(
    peerId: String,
    body: String,
    context: String?,
    targetSessionId: String,
    fromSessionId: String
) async -> SonarSendOutcome {
    guard let url = URL(string: "http://127.0.0.1:4000/api/messages/send") else {
        return .failed("invalid Sonar send URL")
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 10
    var payload: [String: Any] = [
        "peer_id": peerId,
        "question": body,
        "target_session_id": targetSessionId,
        "from_session_id": fromSessionId,
    ]
    if let context { payload["context"] = context }
    do {
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
    } catch {
        return .failed("payload encode failed: \(error)")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            return .failed("non-HTTP response from Sonar send")
        }
        if !(200..<300).contains(http.statusCode) {
            return .failed("Sonar HTTP \(http.statusCode)")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let remoteId = json?["message_id"] as? String
        return .ok(remoteMessageId: remoteId)
    } catch {
        return .failed(error.localizedDescription)
    }
}

