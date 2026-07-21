import Foundation
import GRDB
import SQLite3

// Sonata-side DM routing.
//
// Design principle (2026-07-02): no registry. DB is single source of truth
// for identity. DMs are fire-and-observe — dm_send returns immediately with
// sent | not_live | not_found + optional reason. ACKs arrive async as
// dm_ack notifications on the sender's SSE stream when the receiver's
// worker calls dm_ack(message_id).
//
// Two send paths:
//   dm_send(target, body)             — opens a thread. Target is opaque:
//                                        peer name / local session / worker / supervisor.
//   dm_reply(to_message_id, body)     — continues a thread. Direct routing
//                                        via message chain, no workerEvent.
//
// Endpoints/tools deleted: dm_registry, dm_inbox, dm_poll. If any external
// caller hits these, they get 404.
//
// dm_messages table: append-only audit log. Never read for delivery.

// MARK: - Response types

struct DMSendResponse: Encodable, Sendable {
    let status: String       // "sent" | "not_live" | "not_found"
    let messageId: String?
    let reason: String?
}

struct DMBroadcastResponse: Encodable, Sendable {
    let sent: Int
    let notLive: Int
    let notFound: Int
    let total: Int
    let results: [DMSendResponse]

    enum CodingKeys: String, CodingKey {
        case sent
        case notLive = "not_live"
        case notFound = "not_found"
        case total
        case results
    }
}

struct DMTarget: Encodable, Sendable {
    let name: String
    let kind: String
    let workerId: String?
    let sessionId: String?
    let sessionKey: String?
    let peerId: String?
}

struct DMTargetsResponse: Encodable, Sendable {
    let targets: [DMTarget]
    let generatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case targets
        case generatedAt = "generated_at"
    }
}

struct DMAckResponse: Encodable, Sendable {
    let status: String       // "acknowledged" | "unknown_message"
}

// MARK: - Inbound routing (called by PluginManager.handlePluginEvent)

enum DMActionsInbound {
    /// Inbound DM from a peer, delivered via the sonar plugin's new_message
    /// webhook. Two cases based on `in_reply_to`:
    ///   • present → route DIRECTLY to the original endpoint's SSE (chain
    ///     continuation). No workerEvent.
    ///   • absent  → create a sonar_dm workerEvent for a local worker to
    ///     pick up (thread initiation). Same shape as inbound email.
    static func routePeerInbound(
        payload: [String: Any],
        dbPool: DatabasePool
    ) async {
        let messageId = (payload["message_id"] as? String) ?? newUUID()
        let fromPeerName = payload["from_peer_name"] as? String
        let fromPeerId = payload["from_peer_id"] as? String
        let senderPeerName = fromPeerName ?? fromPeerId ?? "unknown"
        let fromSessionId = payload["from_session_id"] as? String
        let senderDisplay = payload["sender_display"] as? String
        let body = (payload["question"] as? String) ?? (payload["body"] as? String) ?? ""
        let context = payload["context"] as? String
        let inReplyTo = payload["in_reply_to"] as? String
        let now = nowMs()

        // Audit inbound.
        try? await dbPool.write { db in
            try DMAudit.insert(DMAuditRow(
                messageId: messageId,
                target: fromSessionId ?? senderPeerName,
                resolvedSessionKey: nil,
                resolvedKind: nil,
                senderSessionKey: fromSessionId ?? "",
                senderPeerName: senderPeerName,
                body: body,
                context: context,
                sentAtMs: now,
                inReplyToMessageId: inReplyTo,
                direction: "inbound",
                initialStatus: "sent",
                failureReason: nil
            ), db: db)
        }

        if let inReplyTo {
            // Chain-continuation: route DIRECTLY to the original endpoint.
            // Look up the original outbound row and push to its senderSessionKey.
            let originSenderKey: String? = try? await dbPool.read { db in
                try String.fetchOne(db, sql: """
                    SELECT senderSessionKey FROM dm_messages
                    WHERE messageId = ? AND direction = 'outbound'
                """, arguments: [inReplyTo])
            } ?? nil
            guard let originSenderKey, !originSenderKey.isEmpty else {
                sonataFileLog("DMActionsInbound: cannot route reply — no outbound row for in_reply_to=\(inReplyTo)")
                return
            }
            let frame = DMFrames.sonarDMNotification(
                messageId: messageId,
                body: body,
                context: context,
                sender: senderPeerName,
                inReplyToMessageId: inReplyTo
            )
            let pushed = await MCPConnections.shared.push(originSenderKey, jsonRPC: frame)
            if !pushed {
                sonataFileLog("DMActionsInbound: reply target \(originSenderKey) not live — dropping inbound reply \(messageId)")
            } else {
                try? await dbPool.write { db in
                    try DMAudit.markDelivered(messageId: messageId, at: now, db: db)
                }
            }
            return
        }

        // Thread initiation: materialize as a sonar_dm workerEvent for a
        // local worker to pick up. Mirrors inbound email pattern.
        let payloadJSON: [String: Any] = [
            "message_id": messageId,
            "from_peer_name": fromPeerName ?? "",
            "from_peer_id": fromPeerId ?? "",
            "from_session_id": fromSessionId ?? "",
            "sender_display": senderDisplay ?? "",
            "body": body,
            "context": context ?? "",
            "received_at_ms": now,
        ]
        let payloadStr = (try? JSONSerialization.data(withJSONObject: payloadJSON))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let idemKey = WorkerEventIdempotency.key(type: "sonar_dm", payload: payloadJSON)
        try? await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, priority, status, createdAt, idempotencyKey)
                VALUES (?, 'sonar_dm', ?, 5, 'pending', ?, ?)
                ON CONFLICT(idempotencyKey) DO NOTHING
            """, arguments: [newUUID(), payloadStr, now, idemKey])
        }
    }

    /// Peer-forwarded ACK for a DM we originally sent. Update our own
    /// dm_messages audit and push a dm_ack notification to the original
    /// local sender's SSE stream.
    static func routePeerAckForward(
        payload: [String: Any],
        dbPool: DatabasePool
    ) async {
        guard let messageId = payload["message_id"] as? String else { return }
        // JSONSerialization returns numbers as NSNumber on Apple platforms;
        // don't rely on Int/Int64 direct casts (they may fail for large
        // timestamps or lose data). Fetch via NSNumber, then int64Value.
        let ackedAtMs: Int64 = {
            if let n = payload["acked_at_ms"] as? NSNumber { return n.int64Value }
            if let s = payload["acked_at_ms"] as? String, let v = Int64(s) { return v }
            return nowMs()
        }()

        // Look up who originally sent this DM.
        let senderKey: String? = try? await dbPool.read { db in
            try String.fetchOne(db, sql: """
                SELECT senderSessionKey FROM dm_messages
                WHERE messageId = ? AND direction = 'outbound'
            """, arguments: [messageId])
        } ?? nil
        guard let senderKey else {
            sonataFileLog("DMActionsInbound: peer ack for unknown messageId=\(messageId)")
            return
        }
        try? await dbPool.write { db in
            try DMAudit.markAcked(messageId: messageId, at: ackedAtMs, db: db)
        }
        let frame = DMFrames.dmAckNotification(messageId: messageId, ackedAtMs: ackedAtMs)
        _ = await MCPConnections.shared.push(senderKey, jsonRPC: frame)
    }
}

// MARK: - Shared internal helpers

/// Enumerate every currently-live DM-eligible target from DB + connections.
/// Reused by dm_targets handler and dm_broadcast.
func enumerateDMTargets(dbPool: DatabasePool) async -> [DMTarget] {
    var out: [DMTarget] = []
    let conns = MCPConnections.shared

    // Workers.
    if let rows = try? dbPool.read({ db -> [Row] in
        try Row.fetchAll(db, sql: """
            SELECT workerId, sessionLabel FROM workers
            WHERE status != 'offline'
        """)
    }) {
        for row in rows {
            guard let wid: String = row["workerId"],
                  let label: String = row["sessionLabel"] else { continue }
            if await conns.hasLive(wid) {
                out.append(DMTarget(
                    name: label, kind: "worker",
                    workerId: wid, sessionId: nil,
                    sessionKey: wid, peerId: nil
                ))
            }
        }
    }

    // Interactive sessions.
    if let rows = try? dbPool.read({ db -> [Row] in
        try Row.fetchAll(db, sql: """
            SELECT sessionId, name FROM interactiveSessions
            WHERE status = 'live'
        """)
    }) {
        for row in rows {
            guard let sid: String = row["sessionId"],
                  let name: String = row["name"] else { continue }
            let key = "session-" + sid.replacingOccurrences(of: "-", with: "").prefix(16)
            if await conns.hasLive(key) {
                out.append(DMTarget(
                    name: name, kind: "session",
                    workerId: nil, sessionId: sid,
                    sessionKey: key, peerId: nil
                ))
            }
        }
    }

    // Supervisor singleton.
    if await conns.hasLive("supervisor") {
        out.append(DMTarget(
            name: "supervisor", kind: "supervisor",
            workerId: nil, sessionId: nil,
            sessionKey: "supervisor", peerId: nil
        ))
    }

    // Sonar peers — include federation-live ones. Sonar's healthy states
    // are `discovered` and `paired`; blacklist the dead states so future
    // sonar status additions default to visible (matches DMTargetResolver).
    if let peers = await SonarPeerLookup.allPeers() {
        for peer in peers where peer.connectionStatus != "offline"
                                 && peer.connectionStatus != "revoked" {
            out.append(DMTarget(
                name: peer.name, kind: "peer",
                workerId: nil, sessionId: nil,
                sessionKey: nil, peerId: peer.id
            ))
        }
    }
    return out
}

/// Prepend `[from <peer_name>] ` to an outbound cross-peer DM body so the
/// receiver's body-vs-`from_peer_name` comparison never mismatches. Skips
/// the prepend if:
///   - the caller already opened with `[from ` (whatever name — we trust the
///     caller's chosen preamble rather than double-stamping)
///   - self peer name is empty (sonar plugin unreachable — no silent change)
///   - the body already contains the self peer name in its first 32 chars
///     (caller signed by convention — no duplication)
/// Only used for cross-peer sends; local DMs have unambiguous session-key
/// routing and don't need a preamble.
func bodyWithSelfPeerPreamble(body: String) async -> String {
    let selfName = await SonarPeerLookup.selfName()
    guard !selfName.isEmpty else { return body }
    let trimmed = body.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("[from ") { return body }
    let head = String(trimmed.prefix(32)).lowercased()
    if head.contains(selfName.lowercased()) { return body }
    return "[from \(selfName)] \(body)"
}

/// Execute the send pipeline against a resolved target. Handles peer vs
/// local routing, audit persistence, and status/reason mapping. Used by
/// dm_send and dm_broadcast.
func sendResolved(
    target rawTarget: String,
    resolved: DMResolvedTarget,
    body: String,
    context: String?,
    senderKey: String,
    inReplyToMessageId: String?,
    dbPool: DatabasePool
) async -> DMSendResponse {
    let now = nowMs()
    let messageId = newUUID()

    // Audit up front — status defaults to 'sent' and gets updated on failure.
    try? await dbPool.write { db in
        try DMAudit.insert(DMAuditRow(
            messageId: messageId,
            target: rawTarget,
            resolvedSessionKey: resolved.sessionKey,
            resolvedKind: resolved.kind.rawValue,
            senderSessionKey: senderKey,
            senderPeerName: nil,
            body: body,
            context: context,
            sentAtMs: now,
            inReplyToMessageId: inReplyToMessageId,
            direction: "outbound",
            initialStatus: "sent",
            failureReason: nil
        ), db: db)
    }

    switch resolved.kind {
    case .peer:
        guard let peerId = resolved.peerId else {
            try? await dbPool.write { db in
                try DMAudit.markNotLive(messageId: messageId, reason: "peer_offline", db: db)
            }
            return DMSendResponse(status: "not_live", messageId: messageId, reason: "peer_offline")
        }
        // Auto-prepend `[from <peer_name>] ` so the body's identity claim
        // always matches this Sonata's registered peer name on the receiver
        // side. Without this the caller's free-form signature ("evan-mac
        // checking in...") reads as identity-vs-peer-name mismatch to a
        // careful reader and gets flagged. If the caller already opened with
        // a preamble (starts with `[from `), we leave it alone. Blank
        // selfName (sonar unreachable) also leaves the body untouched — no
        // silent behavior change beyond what the caller wrote.
        let bodyToSend = await bodyWithSelfPeerPreamble(body: body)
        let outcome = await sonarPushToPeer(
            peerId: peerId,
            messageId: messageId,
            body: bodyToSend,
            context: context,
            fromSessionId: senderKey,
            inReplyToMessageId: inReplyToMessageId
        )
        switch outcome {
        case .ok:
            try? await dbPool.write { db in
                try DMAudit.markDelivered(messageId: messageId, at: now, db: db)
            }
            return DMSendResponse(status: "sent", messageId: messageId, reason: nil)
        case .failed(let reason):
            try? await dbPool.write { db in
                try DMAudit.markNotLive(messageId: messageId, reason: "peer_offline", db: db)
            }
            sonataFileLog("dm_send: peer forward failed msg=\(messageId): \(reason)")
            return DMSendResponse(status: "not_live", messageId: messageId, reason: "peer_offline")
        }

    case .selfPeer:
        // Shouldn't reach here — caller should map selfPeer to not_found
        // before calling sendResolved. Belt.
        try? await dbPool.write { db in
            try DMAudit.markNotLive(messageId: messageId, reason: "self_peer", db: db)
        }
        return DMSendResponse(status: "not_found", messageId: nil, reason: "self_peer")

    case .worker, .session, .supervisor:
        let frame = DMFrames.sonarDMNotification(
            messageId: messageId,
            body: body,
            context: context,
            sender: senderKey,
            inReplyToMessageId: inReplyToMessageId
        )
        let pushed = await MCPConnections.shared.push(resolved.sessionKey, jsonRPC: frame)
        if !pushed {
            try? await dbPool.write { db in
                try DMAudit.markNotLive(messageId: messageId, reason: "no_live_connection", db: db)
            }
            return DMSendResponse(status: "not_live", messageId: messageId, reason: "no_live_connection")
        }
        try? await dbPool.write { db in
            try DMAudit.markDelivered(messageId: messageId, at: now, db: db)
        }
        return DMSendResponse(status: "sent", messageId: messageId, reason: nil)
    }
}

// MARK: - dm_messages 7-day audit cleanup (unchanged)

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

// MARK: - Public action list

let dmActions: [SonataAction] = [

    // POST /api/dm/send — open a new DM thread.
    SonataAction(
        name: "dm_send",
        description: "Send a DM to any target the system knows about — a worker (by workerId or sessionLabel), an interactive session (by sessionId or tab name), the literal 'supervisor', or a sonar peer (by name). Returns immediately with sent | not_live | not_found and an optional reason. ACK arrives asynchronously as a dm_ack notification on the sender's SSE stream. For replies to an existing thread, use dm_reply instead.",
        group: "/api/dm",
        path: "/send",
        method: .post,
        params: [
            ActionParam("target", .string, required: true, description: "Any identifier for the recipient — name, id, label, 'supervisor', peer name."),
            ActionParam("body", .string, required: true, description: "Message body, ≤ 256 KB."),
            ActionParam("fromSessionId", .string, required: true, description: "Sender's sessionKey."),
            ActionParam("context", .string, required: false, description: "Optional context string, passed through to the receiver."),
        ],
        handler: { ctx in
            let target = try ctx.params.require("target")
            let body = try ctx.params.require("body")
            let senderKey = try ctx.params.require("fromSessionId")
            let context = ctx.params.string("context")

            guard body.utf8.count <= 256 * 1024 else {
                throw ActionError.custom("body_too_large", .unprocessableContent)
            }
            guard !body.isEmpty else {
                throw ActionError.custom("body_empty", .unprocessableContent)
            }

            guard let resolved = await DMTargetResolver.resolve(target, dbPool: ctx.dbPool) else {
                // Distinguish "typo / no such target" from "sonar offline"
                // via a fast probe on the peer plugin.
                let reason: String
                if await SonarPeerLookup.pluginReachable() {
                    reason = "no_such_target"
                } else {
                    reason = "sonar_offline"
                }
                let now = nowMs()
                try? await ctx.dbPool.write { db in
                    try DMAudit.insert(DMAuditRow(
                        messageId: newUUID(),
                        target: target,
                        resolvedSessionKey: nil,
                        resolvedKind: nil,
                        senderSessionKey: senderKey,
                        senderPeerName: nil,
                        body: body,
                        context: context,
                        sentAtMs: now,
                        inReplyToMessageId: nil,
                        direction: "outbound",
                        initialStatus: "not_found",
                        failureReason: reason
                    ), db: db)
                }
                return DMSendResponse(status: "not_found", messageId: nil, reason: reason)
            }
            if resolved.kind == .selfPeer {
                let now = nowMs()
                try? await ctx.dbPool.write { db in
                    try DMAudit.insert(DMAuditRow(
                        messageId: newUUID(),
                        target: target,
                        resolvedSessionKey: nil,
                        resolvedKind: "selfPeer",
                        senderSessionKey: senderKey,
                        senderPeerName: nil,
                        body: body,
                        context: context,
                        sentAtMs: now,
                        inReplyToMessageId: nil,
                        direction: "outbound",
                        initialStatus: "not_found",
                        failureReason: "self_peer"
                    ), db: db)
                }
                return DMSendResponse(status: "not_found", messageId: nil, reason: "self_peer")
            }

            return await sendResolved(
                target: target,
                resolved: resolved,
                body: body,
                context: context,
                senderKey: senderKey,
                inReplyToMessageId: nil,
                dbPool: ctx.dbPool
            )
        }
    ),

    // POST /api/dm/reply — continue an existing DM thread.
    SonataAction(
        name: "dm_reply",
        description: "Reply to a prior DM by messageId. Routes directly to the original endpoint via the message chain — no workerEvent is created on the receive side. If the original endpoint is no longer live (session closed, worker gone, peer offline), returns not_live. Use dm_send to open a new thread.",
        group: "/api/dm",
        path: "/reply",
        method: .post,
        params: [
            ActionParam("to_message_id", .string, required: true, description: "The messageId of the prior DM this is a reply to."),
            ActionParam("body", .string, required: true, description: "Reply body, ≤ 256 KB."),
            ActionParam("fromSessionId", .string, required: true, description: "Sender's sessionKey."),
        ],
        handler: { ctx in
            let toMessageId = try ctx.params.require("to_message_id")
            let body = try ctx.params.require("body")
            let senderKey = try ctx.params.require("fromSessionId")
            guard body.utf8.count <= 256 * 1024 else {
                throw ActionError.custom("body_too_large", .unprocessableContent)
            }
            guard !body.isEmpty else {
                throw ActionError.custom("body_empty", .unprocessableContent)
            }

            // Look up the prior audit row.
            let prior: (senderSessionKey: String?, resolvedSessionKey: String?, resolvedKind: String?, senderPeerName: String?, direction: String)? =
                try? await ctx.dbPool.read { db in
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT senderSessionKey, resolvedSessionKey, resolvedKind,
                               senderPeerName, direction
                        FROM dm_messages WHERE messageId = ?
                    """, arguments: [toMessageId]) else { return nil }
                    return (
                        row["senderSessionKey"] as? String,
                        row["resolvedSessionKey"] as? String,
                        row["resolvedKind"] as? String,
                        row["senderPeerName"] as? String,
                        row["direction"] as? String ?? "outbound"
                    )
                } ?? nil

            guard let prior else {
                return DMSendResponse(status: "not_found", messageId: nil, reason: "unknown_prior_message")
            }

            // Determine reply target from the chain. Two axes:
            //   • direction of the prior (outbound = we sent it; inbound = we
            //     received it from a peer)
            //   • caller identity relative to the prior (are we the original
            //     sender following up, or the original recipient replying?)
            //
            // Outbound prior:
            //   • caller == prior.senderSessionKey → follow-up → route to
            //     the original RECIPIENT (prior.resolvedSessionKey)
            //   • caller != prior.senderSessionKey → this caller RECEIVED the
            //     DM via SSE push and is replying → route to the original
            //     SENDER (prior.senderSessionKey)
            //
            // Inbound prior (we materialized it from a peer webhook):
            //   • Route back through the peer (senderPeerName) with an
            //     in_reply_to marker so the origin peer routes directly to
            //     the specific session that sent it.
            let replyTarget: DMResolvedTarget
            let replyTargetName: String    // for audit `target` column
            if prior.direction == "outbound" {
                let priorSender = prior.senderSessionKey ?? ""
                if senderKey == priorSender && !priorSender.isEmpty {
                    // Follow-up from the original sender → send to the recipient.
                    guard let sessKey = prior.resolvedSessionKey,
                          let kindStr = prior.resolvedKind,
                          let kind = DMTargetKind(rawValue: kindStr),
                          !sessKey.isEmpty else {
                        return DMSendResponse(status: "not_found", messageId: nil, reason: "cannot_resolve_reply_target")
                    }
                    replyTarget = DMResolvedTarget(
                        sessionKey: sessKey, kind: kind,
                        peerId: kind == .peer ? sessKey : nil,
                        sessionId: nil
                    )
                    replyTargetName = sessKey
                } else if !priorSender.isEmpty {
                    // Reply from the original RECIPIENT → send back to the
                    // original SENDER. Infer kind from the sessionKey shape.
                    let kind: DMTargetKind = priorSender.hasPrefix("worker-") ? .worker :
                        (priorSender == "supervisor" ? .supervisor : .session)
                    replyTarget = DMResolvedTarget(
                        sessionKey: priorSender, kind: kind,
                        peerId: nil, sessionId: nil
                    )
                    replyTargetName = priorSender
                } else {
                    return DMSendResponse(status: "not_found", messageId: nil, reason: "cannot_resolve_reply_target")
                }
            } else {
                // Inbound prior — we received this DM from a peer webhook.
                if let peerName = prior.senderPeerName, !peerName.isEmpty {
                    guard let peer = await SonarPeerLookup.byName(peerName.lowercased()) else {
                        return DMSendResponse(status: "not_found", messageId: nil, reason: "unknown_peer")
                    }
                    replyTarget = DMResolvedTarget(sessionKey: peer.id, kind: .peer, peerId: peer.id, sessionId: nil)
                    replyTargetName = peerName
                } else if let senderKeyPrior = prior.senderSessionKey, !senderKeyPrior.isEmpty {
                    // Defensive fallback for hypothetical inbound-with-local-sender.
                    let kind: DMTargetKind = senderKeyPrior.hasPrefix("worker-") ? .worker :
                        (senderKeyPrior == "supervisor" ? .supervisor : .session)
                    replyTarget = DMResolvedTarget(sessionKey: senderKeyPrior, kind: kind, peerId: nil, sessionId: nil)
                    replyTargetName = senderKeyPrior
                } else {
                    return DMSendResponse(status: "not_found", messageId: nil, reason: "cannot_resolve_reply_target")
                }
            }

            let result = await sendResolved(
                target: replyTargetName,
                resolved: replyTarget,
                body: body,
                context: nil,
                senderKey: senderKey,
                inReplyToMessageId: toMessageId,
                dbPool: ctx.dbPool
            )

            // Auto-complete safety net (2026-07-09): if this dm_reply is the
            // caller replying to a sonar_dm workerEvent they were assigned,
            // mark that event completed and free the worker. Guards against
            // worker Claude sessions that skip step 5 of the SONAR_DM
            // contract (call complete_event) after replying. Matches on
            //   (a) the caller currently owns an ASSIGNED sonar_dm event
            //   (b) that event's payload.message_id equals to_message_id
            // If either fails, this is a no-op — normal complete_event flow
            // still applies for callers who follow the contract correctly.
            if result.status == "sent" {
                try? await ctx.dbPool.write { db in
                    // Match the exact event by message_id IN SQL. Previously
                    // this used fetchOne with no message_id filter and no
                    // ORDER BY, then compared in Swift — so a leftover stale
                    // sonar_dm event assigned to the same worker could be
                    // returned instead of the one being replied to, the
                    // comparison failed, and the auto-complete silently
                    // no-op'd, leaving the worker stuck 'busy' (2026-07-17).
                    // Filtering by message_id targets the right row regardless
                    // of stale siblings.
                    guard let eventId = try String.fetchOne(db, sql: """
                        SELECT id FROM workerEvents
                        WHERE assignedTo = ? AND status = 'assigned' AND type = 'sonar_dm'
                          AND json_extract(payload, '$.message_id') = ?
                        LIMIT 1
                    """, arguments: [senderKey, toMessageId]), !eventId.isEmpty else { return }
                    let now = nowMs()
                    try db.execute(sql: """
                        UPDATE workerEvents SET status = 'completed', completedAt = ?,
                            result = 'auto-completed via dm_reply'
                        WHERE id = ? AND status = 'assigned'
                    """, arguments: [now, eventId])
                    try db.execute(sql: """
                        UPDATE workers SET status = 'idle', currentEventId = NULL
                        WHERE workerId = ? AND currentEventId = ?
                    """, arguments: [senderKey, eventId])
                }
            }

            return result
        }
    ),

    // POST /api/dm/ack — receiver's ack of a DM they processed.
    SonataAction(
        name: "dm_ack",
        description: "Acknowledge receipt of a DM. Called by the receiver as an early confirmation for a sonar_dm workerEvent (before dm_reply / complete_event). Sonata updates the audit row and forwards the ack to the sender's SSE stream so they know their message was received.",
        group: "/api/dm",
        path: "/ack",
        method: .post,
        params: [
            ActionParam("messageId", .string, required: true, description: "The messageId from the sonar_dm workerEvent payload."),
        ],
        handler: { ctx in
            let messageId = try ctx.params.require("messageId")
            let now = nowMs()

            // Fetch the audit row to determine sender identity and whether
            // this was an inbound-from-peer DM (in which case we forward the
            // ack back via sonar) or a local DM (push to sender's SSE).
            let audit: (senderSessionKey: String?, senderPeerName: String?, direction: String)? =
                try? await ctx.dbPool.read { db in
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT senderSessionKey, senderPeerName, direction
                        FROM dm_messages WHERE messageId = ?
                    """, arguments: [messageId]) else { return nil }
                    return (
                        row["senderSessionKey"] as? String,
                        row["senderPeerName"] as? String,
                        row["direction"] as? String ?? "outbound"
                    )
                } ?? nil

            guard let audit else {
                return DMAckResponse(status: "unknown_message")
            }

            try? await ctx.dbPool.write { db in
                try DMAudit.markAcked(messageId: messageId, at: now, db: db)
            }

            if audit.direction == "inbound", let peerName = audit.senderPeerName,
               let peer = await SonarPeerLookup.byName(peerName.lowercased()) {
                // Ack forwards back through sonar to the origin peer, which
                // updates its own audit + pushes dm_ack to its local sender.
                _ = await sonarPushAckToPeer(peerId: peer.id, messageId: messageId, ackedAtMs: now)
            } else if let senderKey = audit.senderSessionKey, !senderKey.isEmpty {
                // Local DM — push dm_ack notification directly to the sender's SSE.
                let frame = DMFrames.dmAckNotification(messageId: messageId, ackedAtMs: now)
                _ = MCPConnections.shared.push(senderKey, jsonRPC: frame)
            }

            return DMAckResponse(status: "acknowledged")
        }
    ),

    // GET /api/dm/targets — enumerate every currently-DM-able target.
    SonataAction(
        name: "dm_targets",
        description: "List every session, worker, supervisor session, and sonar peer currently DM-able. Presence in this list means a DM can be pushed live right now.",
        group: "/api/dm",
        path: "/targets",
        method: .get,
        params: [],
        handler: { ctx in
            let targets = await enumerateDMTargets(dbPool: ctx.dbPool)
            return DMTargetsResponse(targets: targets, generatedAt: nowMs())
        }
    ),

    // POST /api/dm/broadcast — fan to every matching target.
    SonataAction(
        name: "dm_broadcast",
        description: "Send a DM to every currently-DM-able target matching the filter. Filter values: 'all' | 'workers' | 'sessions' | 'supervisor' | 'peers'. Excludes the sender.",
        group: "/api/dm",
        path: "/broadcast",
        method: .post,
        params: [
            ActionParam("fromSessionId", .string, required: true, description: "Sender's sessionKey."),
            ActionParam("body", .string, required: true, description: "Message body, ≤ 256 KB."),
            ActionParam("filter", .string, required: false, description: "Recipient kind filter (default 'all')."),
            ActionParam("context", .string, required: false, description: "Optional context string."),
        ],
        handler: { ctx in
            let senderKey = try ctx.params.require("fromSessionId")
            let body = try ctx.params.require("body")
            guard body.utf8.count <= 256 * 1024 else {
                throw ActionError.custom("body_too_large", .unprocessableContent)
            }
            let filter = (ctx.params.string("filter") ?? "all").lowercased()
            let context = ctx.params.string("context")

            let allTargets = await enumerateDMTargets(dbPool: ctx.dbPool)
            let filtered = allTargets.filter { t in
                if t.sessionKey == senderKey { return false }
                switch filter {
                case "all": return true
                case "workers", "worker": return t.kind == "worker"
                case "sessions", "session", "interactive", "humans": return t.kind == "session"
                case "supervisor": return t.kind == "supervisor"
                case "peers", "peer": return t.kind == "peer"
                default: return false
                }
            }

            var results: [DMSendResponse] = []
            var sent = 0, notLive = 0, notFound = 0
            for t in filtered {
                let kind = DMTargetKind(rawValue: t.kind) ?? .session
                let resolved = DMResolvedTarget(
                    sessionKey: t.sessionKey ?? (t.peerId ?? ""),
                    kind: kind,
                    peerId: t.peerId,
                    sessionId: t.sessionId
                )
                let res = await sendResolved(
                    target: t.name,
                    resolved: resolved,
                    body: body,
                    context: context,
                    senderKey: senderKey,
                    inReplyToMessageId: nil,
                    dbPool: ctx.dbPool
                )
                switch res.status {
                case "sent": sent += 1
                case "not_live": notLive += 1
                case "not_found": notFound += 1
                default: break
                }
                results.append(res)
            }
            return DMBroadcastResponse(
                sent: sent, notLive: notLive, notFound: notFound,
                total: results.count, results: results
            )
        }
    ),
]
