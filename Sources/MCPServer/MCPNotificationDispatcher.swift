import Foundation

final class MCPNotificationDispatcher: @unchecked Sendable {
    static let shared = MCPNotificationDispatcher()

    /// Push an arbitrary `notifications/claude/channel` frame to a session.
    /// Returns true if the session had a live SSE writer.
    @discardableResult
    func pushChannel(
        sessionKey: String,
        content: String,
        meta: [String: String]
    ) async -> Bool {
        let params: [String: Any] = ["content": content, "meta": meta]
        let frame = DMFrames.notification(
            method: "notifications/claude/channel", params: params
        )
        return await MCPConnections.shared.push(sessionKey, jsonRPC: frame)
    }

    @discardableResult
    func pushWorkerEvent(
        sessionKey: String,
        eventId: String,
        eventType: String,
        priority: Int,
        createdAt: Int64,
        content: String
    ) async -> Bool {
        let meta: [String: String] = [
            "event_id": eventId,
            "event_type": eventType,
            "priority": String(priority),
            "timestamp": ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000.0)),
        ]
        return await pushChannel(
            sessionKey: sessionKey,
            content: "[\(eventType.uppercased())] \(content)",
            meta: meta
        )
    }

    @discardableResult
    func pushSupervisorEvent(
        eventId: String, eventType: String, content: String
    ) async -> Bool {
        let meta: [String: String] = [
            "event_id": eventId,
            "event_type": eventType,
        ]
        return await pushChannel(sessionKey: "supervisor", content: content, meta: meta)
    }

    @discardableResult
    func pushAFKReply(
        sessionKey: String,
        fromAddr: String,
        subject: String,
        messageId: String,
        replyText: String
    ) async -> Bool {
        let content = """
            [AFK reply]
            From: \(fromAddr)
            Subject: \(subject)

            \(replyText)
            """
        let meta: [String: String] = [
            "event_type": "afk_reply",
            "message_id": messageId,
            "from_addr": fromAddr,
            "subject": subject,
        ]
        return await pushChannel(sessionKey: sessionKey, content: content, meta: meta)
    }

    @discardableResult
    func pushSonataRestart(
        sessionKey: String, taskId: String, lastEventId: String
    ) async -> Bool {
        let restartedAt = nowMs()
        let content = """
            [SONATA_RESTART] task=\(taskId) ts=\(restartedAt)
            Sonata.app was restarted. You are resumed in your prior conversation. Look at your most recent action — if it was a tool call without a result, decide whether to retry, recover, or continue. Otherwise carry on.
            """
        let meta: [String: String] = [
            "event_type": "sonata_restart",
            "task_id": taskId,
            "last_event_id": lastEventId,
            "restarted_at_ms": String(restartedAt),
        ]
        return await pushChannel(sessionKey: sessionKey, content: content, meta: meta)
    }

    /// Broadcast tools/list_changed to every attached session so clients
    /// re-request tools/list. Called when a plugin registers new actions.
    func broadcastToolsListChanged() async {
        let frame = DMFrames.notification(
            method: "notifications/tools/list_changed", params: [:]
        )
        _ = await MCPConnections.shared.broadcast(jsonRPC: frame)
    }
}
