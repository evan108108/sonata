import Foundation

final class MCPNotificationDispatcher: @unchecked Sendable {
    static let shared = MCPNotificationDispatcher()

    private let lock = NSLock()
    private var registry: MCPSessionRegistry?
    private var bound: Bool = false

    func bind(registry: MCPSessionRegistry) async {
        guard claimBound(registry) else { return }
        AFKRegistry.shared.setDeliveryHook { [weak self] sessionId, reply in
            Task { [weak self] in
                let delivered = await self?.pushAFKReply(sessionKey: sessionId, reply: reply) ?? false
                // FIX #2: only drop the reply from the durable outbox once the
                // push actually landed. A failed push leaves it for the next
                // reconnect/poll to drain.
                if delivered {
                    AFKRegistry.shared.ackReply(sessionId: sessionId, replyId: reply.id)
                }
            }
        }
        AFKRegistry.shared.drainPendingForHook()
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

    @discardableResult
    private func pushAFKReply(sessionKey: String, reply: AFKReply) async -> Bool {
        let content = """
            [AFK reply for token \(reply.token)]
            From: \(reply.fromAddr)
            Subject: \(reply.subject)

            \(reply.replyText)
            """
        let meta: [String: String] = [
            "event_type": "afk_reply",
            "afk_token": reply.token,
            "message_id": reply.messageId,
            "from_addr": reply.fromAddr,
            "subject": reply.subject,
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
