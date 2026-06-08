import Foundation

final class MCPNotificationDispatcher: @unchecked Sendable {
    static let shared = MCPNotificationDispatcher()

    private let lock = NSLock()
    private var registry: MCPSessionRegistry?
    private var bound: Bool = false

    func bind(registry: MCPSessionRegistry) async {
        guard claimBound(registry) else { return }
        // AFK replies route directly through EmailHandler now — no registry,
        // no outbox, no delivery hook. EmailHandler parses the sessionId from
        // the `[AFK-#<sessionId>]` subject and calls pushAFKReply on the
        // resolved live session. See Sources/Scheduler/EmailHandler.swift.
    }

    private func claimBound(_ registry: MCPSessionRegistry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if bound { return false }
        self.registry = registry
        bound = true
        return true
    }

    @discardableResult
    func pushChannel(
        sessionKey: String,
        content: String,
        meta: [String: String]
    ) async -> Bool {
        guard let registry = currentRegistry() else { return false }
        let params: [String: Any] = ["content": content, "meta": meta]
        return await registry.pushNotification(
            sessionKey: sessionKey,
            method: "notifications/claude/channel",
            params: params
        )
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
        return await pushChannel(
            sessionKey: "supervisor",
            content: content,
            meta: meta
        )
    }

    /// Push an AFK email reply to a live session as a channel notification.
    /// Called by EmailHandler after it has parsed the sessionId from a
    /// `[AFK-#<sessionId>]` subject and resolved it to a live sessionKey
    /// via MCPSessionRegistry. The receiving session's AFK skill matches
    /// on `meta.event_type == "afk_reply"`.
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

    private func currentRegistry() -> MCPSessionRegistry? {
        lock.lock(); defer { lock.unlock() }
        return registry
    }
}
