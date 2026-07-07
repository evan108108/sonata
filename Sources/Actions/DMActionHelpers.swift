import Foundation
import GRDB

// MARK: - JSON-RPC frame builders

enum DMFrames {
    /// Builds a JSON-RPC 2.0 notification (no id) as an already-serialized string.
    static func notification(method: String, params: [String: Any]) -> String {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The `notifications/claude/channel` frame carrying a sonar_dm event.
    /// The receiver's claude sees this in its <channel source="sonata-bridge">
    /// context and handles it per the SONAR_DM instructions.
    static func sonarDMNotification(
        messageId: String,
        body: String,
        context: String?,
        sender: String,
        inReplyToMessageId: String?
    ) -> String {
        var meta: [String: Any] = [
            "event_type": "sonar_dm",
            "message_id": messageId,
            "from_session_id": sender,
        ]
        if let context { meta["context"] = context }
        if let inReplyToMessageId { meta["in_reply_to"] = inReplyToMessageId }
        let params: [String: Any] = [
            "content": "[DM from \(sender)]\n\(body)",
            "meta": meta,
        ]
        return notification(method: "notifications/claude/channel", params: params)
    }

    /// The `dm_ack` notification pushed back to the original sender when a
    /// receiver's `dm_ack` MCP call lands. Sender's claude correlates by
    /// messageId with any pending sends it's tracking.
    static func dmAckNotification(
        messageId: String,
        ackedAtMs: Int64
    ) -> String {
        let meta: [String: Any] = [
            "event_type": "dm_ack",
            "message_id": messageId,
            "acked_at_ms": ackedAtMs,
        ]
        let params: [String: Any] = [
            "content": "DM \(messageId) acknowledged",
            "meta": meta,
        ]
        return notification(method: "notifications/claude/channel", params: params)
    }
}

// MARK: - dm_messages audit persistence

/// Row inserted at the start of every dm_send / dm_reply. UPDATEd with
/// deliveredAtMs on successful push, or failureReason on failure.
struct DMAuditRow {
    let messageId: String
    let target: String                  // raw sender input (may be name, id, etc.)
    let resolvedSessionKey: String?
    let resolvedKind: String?
    let senderSessionKey: String
    let senderPeerName: String?         // inbound only — populated on receiving side
    let body: String
    let context: String?
    let sentAtMs: Int64
    let inReplyToMessageId: String?
    let direction: String               // "outbound" | "inbound"
    let initialStatus: String           // "sent" | "not_live" | "not_found"
    let failureReason: String?
}

enum DMAudit {
    static func insert(_ row: DMAuditRow, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO dm_messages (
                messageId, targetSessionId, resolvedSessionKey, resolvedKind,
                senderSessionKey, senderPeerName, body, context,
                sentAtMs, receivedAtMs, deliveryStatus,
                inReplyToMessageId, direction, failureReason,
                fromSessionId
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            row.messageId, row.target,
            row.resolvedSessionKey, row.resolvedKind,
            row.senderSessionKey, row.senderPeerName,
            row.body, row.context,
            row.sentAtMs, row.sentAtMs, row.initialStatus,
            row.inReplyToMessageId, row.direction, row.failureReason,
            row.senderSessionKey,   // fromSessionId kept for backcompat with the v9 column
        ])
    }

    static func markDelivered(messageId: String, at: Int64, db: Database) throws {
        try db.execute(sql: """
            UPDATE dm_messages SET deliveredAtMs = ? WHERE messageId = ?
        """, arguments: [at, messageId])
    }

    static func markNotLive(messageId: String, reason: String, db: Database) throws {
        try db.execute(sql: """
            UPDATE dm_messages SET deliveryStatus = 'not_live', failureReason = ?
            WHERE messageId = ?
        """, arguments: [reason, messageId])
    }

    static func markAcked(messageId: String, at: Int64, db: Database) throws {
        try db.execute(sql: """
            UPDATE dm_messages SET ackedAtMs = ? WHERE messageId = ?
        """, arguments: [at, messageId])
    }
}

// MARK: - Sonar forward (peer delivery)

/// Outcome of a POST to the sonar plugin's /api/messages/send.
enum SonarForwardOutcome {
    case ok(remoteMessageId: String?)
    case failed(reason: String)
}

/// Forward a DM to a peer via the sonar plugin. The plugin handles trust,
/// signing, and network transport. `inReplyToMessageId` tells the receiving
/// peer this is a chain-continuation — they'll route directly to the
/// original endpoint instead of creating a workerEvent.
func sonarPushToPeer(
    peerId: String,
    messageId: String,
    body: String,
    context: String?,
    fromSessionId: String,
    inReplyToMessageId: String? = nil
) async -> SonarForwardOutcome {
    guard let url = URL(string: "http://127.0.0.1:4000/api/messages/send") else {
        return .failed(reason: "invalid Sonar send URL")
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 10

    var payload: [String: Any] = [
        "peer_id": peerId,
        "message_id": messageId,
        "question": body,
        "from_session_id": fromSessionId,
    ]
    if let context { payload["context"] = context }
    if let inReplyToMessageId { payload["in_reply_to"] = inReplyToMessageId }

    do {
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
    } catch {
        return .failed(reason: "payload encode failed: \(error.localizedDescription)")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            return .failed(reason: "non-HTTP response from Sonar send")
        }
        if !(200..<300).contains(http.statusCode) {
            return .failed(reason: "Sonar HTTP \(http.statusCode)")
        }
        // A 2xx alone is not delivery — sonar historically returned
        // 202 {status:"pending"} even when the downstream relay failed.
        // Only "relayed" means the message actually reached the peer.
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = json["status"] as? String else {
            return .failed(reason: "missing_status")
        }
        switch status {
        case "relayed":
            return .ok(remoteMessageId: json["message_id"] as? String)
        case "pending":
            return .failed(reason: "pending_no_relay")
        default:
            if let failureReason = json["failure_reason"] as? String {
                return .failed(reason: "relay_failed: \(failureReason)")
            }
            return .failed(reason: "unexpected_status: \(status)")
        }
    } catch {
        return .failed(reason: error.localizedDescription)
    }
}

/// Forward a DM ACK back to the peer that originated the DM. Used when a
/// local worker calls dm_ack for a DM that came in from a peer. Sonar
/// carries a small "ack_forward" payload back so the origin peer can
/// update its audit + push dm_ack notification to the original sender's SSE.
func sonarPushAckToPeer(
    peerId: String,
    messageId: String,
    ackedAtMs: Int64
) async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:4000/api/messages/ack_forward") else {
        return false
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 5
    let payload: [String: Any] = [
        "peer_id": peerId,
        "message_id": messageId,
        "acked_at_ms": ackedAtMs,
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
        return false
    }
    req.httpBody = body
    do {
        let (_, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            return true
        }
        return false
    } catch {
        return false
    }
}
