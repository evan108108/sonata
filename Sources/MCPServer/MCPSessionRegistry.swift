import Foundation
import GRDB

actor MCPSessionRegistry {
    /// Set once during SonataApp HTTP-server startup. Coordinators that
    /// spawn claude sessions (Supervisor / Worker / Interactive / Inspector)
    /// read this to obtain the registry for credential issuance without
    /// having to plumb it through every constructor. Nil during the brief
    /// window before SonataApp publishes it; coordinators treat that as
    /// "fall back to legacy env-var bridge."
    nonisolated(unsafe) static var shared: MCPSessionRegistry?

    private var sessions: [String: MCPSessionState] = [:]
    private var tokens: [String: String] = [:]

    let dbPool: DatabasePool
    let actionRegistry: ActionRegistry

    init(dbPool: DatabasePool, actionRegistry: ActionRegistry) {
        self.dbPool = dbPool
        self.actionRegistry = actionRegistry
    }

    func registerToken(sessionKey: String, token: String, role: SessionRole) {
        tokens[sessionKey] = token
        if sessions[sessionKey] == nil {
            sessions[sessionKey] = MCPSessionState(
                sessionKey: sessionKey,
                role: role,
                dbPool: dbPool,
                actionRegistry: actionRegistry,
                registry: self
            )
        }
    }

    func rotateToken(sessionKey: String) -> String {
        let newToken = MCPTokenGenerator.newToken()
        tokens[sessionKey] = newToken
        return newToken
    }

    func validateBearer(sessionKey: String, suppliedToken: String?) -> Bool {
        guard let suppliedToken else { return false }
        guard let expected = tokens[sessionKey] else { return false }
        return MCPCryptoCompare.equals(expected, suppliedToken)
    }

    func get(_ sessionKey: String) -> MCPSessionState? {
        sessions[sessionKey]
    }

    func getOrCreate(_ sessionKey: String, inferRole: () async -> SessionRole) async -> MCPSessionState {
        if let existing = sessions[sessionKey] { return existing }
        let role = await inferRole()
        let state = MCPSessionState(
            sessionKey: sessionKey,
            role: role,
            dbPool: dbPool,
            actionRegistry: actionRegistry,
            registry: self
        )
        sessions[sessionKey] = state
        return state
    }

    func evict(_ sessionKey: String) async {
        if let state = sessions.removeValue(forKey: sessionKey) {
            await state.sseWriter?.close()
        }
        tokens.removeValue(forKey: sessionKey)
    }

    struct SessionSnapshot: Sendable {
        let sessionKey: String
        let role: SessionRole
        let lastContactedAt: Int64
        let hasSSE: Bool
        let inFlightEventId: String?
    }

    func snapshot() async -> [SessionSnapshot] {
        var out: [SessionSnapshot] = []
        for (key, state) in sessions {
            let last = await state.lastContactedAt
            let role = await state.role
            let hasSSE = await (state.sseWriter != nil)
            let inFlight = await state.inFlightEventId
            out.append(SessionSnapshot(
                sessionKey: key,
                role: role,
                lastContactedAt: last,
                hasSSE: hasSSE,
                inFlightEventId: inFlight
            ))
        }
        return out
    }

    func pushNotification(
        sessionKey: String,
        method: String,
        params: [String: Any]
    ) async -> Bool {
        guard let state = sessions[sessionKey] else { return false }
        await state.pushNotification(method: method, params: params)
        return true
    }

    func tickKeepAlives() async {
        for state in sessions.values {
            if let writer = await state.sseWriter, !writer.isClosed {
                writer.sendKeepAlive()
            }
        }
    }

    /// Atomic check-then-push for local DM delivery (see plan §4 "The DM
    /// registry goes away entirely"). Returns true if the target session
    /// is attached to an SSE writer and the notification was pushed;
    /// false otherwise.
    func deliverDM(
        target: String,
        messageId: String,
        body: String,
        fromSessionId: String,
        context: String?,
        metaJson: String?,
        sentAtMs: Int64
    ) async -> Bool {
        guard let state = sessions[target] else { return false }
        let hasSSE = await (state.sseWriter != nil)
        guard hasSSE else { return false }
        let content = "[DM from \(fromSessionId)]\n\(body)"
        let params: [String: Any] = [
            "content": content,
            "meta": [
                "event_type": "sonar_dm",
                "message_id": messageId,
                "from_session_id": fromSessionId,
                "from_pubkey": "",
                "from_peer_id": "",
                "target_session_id": target,
                "sent_at_ms": String(sentAtMs),
                "context": context ?? "",
                "meta_json": metaJson ?? "",
            ],
        ]
        await state.pushNotification(
            method: "notifications/claude/channel", params: params)
        return true
    }
}
