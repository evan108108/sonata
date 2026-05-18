import Foundation
import GRDB

actor MCPSessionState {
    let sessionKey: String
    var role: SessionRole
    var lastContactedAt: Int64
    private(set) var sseWriter: MCPSSEWriter?
    var inFlightEventId: String?
    var sessionLabel: String?

    private(set) var protocolVersion: String = "2025-03-26"

    private let dbPool: DatabasePool
    private let actionRegistry: ActionRegistry
    private weak var registry: MCPSessionRegistry?

    init(
        sessionKey: String,
        role: SessionRole,
        dbPool: DatabasePool,
        actionRegistry: ActionRegistry,
        registry: MCPSessionRegistry
    ) {
        self.sessionKey = sessionKey
        self.role = role
        self.dbPool = dbPool
        self.actionRegistry = actionRegistry
        self.registry = registry
        self.lastContactedAt = Int64(Date().timeIntervalSince1970 * 1000)
    }

    func touch() {
        lastContactedAt = Int64(Date().timeIntervalSince1970 * 1000)
    }

    func attachSSE(_ writer: MCPSSEWriter) {
        sseWriter?.close()
        sseWriter = writer
    }

    func detachSSE(_ writer: MCPSSEWriter) {
        if sseWriter === writer {
            sseWriter = nil
        }
    }

    func pushNotification(method: String, params: [String: Any]) {
        guard let writer = sseWriter, !writer.isClosed else { return }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        // SSE data: frames must NOT contain raw newlines; .sortedKeys (no
        // .prettyPrinted) keeps the JSON on one line. Do not switch to
        // .prettyPrinted here — it would corrupt every SSE frame.
        guard let data = try? JSONSerialization.data(
                withJSONObject: envelope, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return
        }
        writer.send(jsonRPC: str)
    }

    func handle(
        method: String,
        id: Any?,
        params: [String: Any]
    ) async -> String? {
        touch()
        if id == nil { return nil }
        switch method {
        case "initialize":
            return handleInitialize(id: id!, params: params)
        case "ping":
            return jsonRPCResult(id: id!, result: [:])
        case "tools/list":
            return handleToolsList(id: id!)
        case "tools/call":
            return await handleToolsCall(id: id!, params: params)
        case "resources/list":
            return jsonRPCResult(id: id!, result: ["resources": []])
        case "prompts/list":
            return jsonRPCResult(id: id!, result: ["prompts": []])
        default:
            return jsonRPCError(
                id: id!,
                code: -32601,
                message: "Method not found: \(method)"
            )
        }
    }

    private func handleInitialize(id: Any, params: [String: Any]) -> String {
        if let pv = params["protocolVersion"] as? String {
            protocolVersion = pv
        }
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [
                "tools": [:],
                "experimental": ["claude/channel": [:]],
            ],
            "serverInfo": [
                "name": "sonata-bridge",
                "version": "1.0.0",
            ],
            "instructions": MCPInstructions.workerInstructions,
        ]
        return jsonRPCResult(id: id, result: result)
    }

    private func handleToolsList(id: Any) -> String {
        return jsonRPCResult(id: id, result: ["tools": MCPToolSchemas.all])
    }

    private func handleToolsCall(id: Any, params: [String: Any]) async -> String {
        guard let toolName = params["name"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let registry = self.registry else {
            return jsonRPCError(id: id, code: -32603,
                message: "MCP registry deallocated mid-call")
        }
        let (success, output) = await MCPToolHandlers.handle(
            toolName: toolName,
            args: args,
            role: role,
            sessionKey: sessionKey,
            state: self,
            registry: registry,
            actionRegistry: actionRegistry,
            dbPool: dbPool
        )
        let content: [[String: Any]] = [["type": "text", "text": output]]
        var result: [String: Any] = ["content": content]
        if !success { result["isError"] = true }
        return jsonRPCResult(id: id, result: result)
    }

    func markInFlight(eventId: String) { inFlightEventId = eventId }
    func clearInFlight() { inFlightEventId = nil }

    private func jsonRPCResult(id: Any, result: Any) -> String {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id is NSNull ? NSNull() : id,
            "result": result,
        ]
        return serialize(envelope)
    }

    private func jsonRPCError(id: Any, code: Int, message: String) -> String {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id is NSNull ? NSNull() : id,
            "error": ["code": code, "message": message],
        ]
        return serialize(envelope)
    }

    private func serialize(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal serialization error\"}}"
        }
        return str
    }
}

enum MCPInstructions {
    static let workerInstructions: String = """
        You are a Sona Worker receiving events from the Sonata backend via the sonata-bridge channel.

        When a <channel source="sonata-bridge"> event arrives, it contains a work item. The meta attributes include:
        - event_id: the event ID (use for completing events)
        - event_type: the type of event (email, task, alert, etc.)

        IMPORTANT: Before processing ANY event:
        1. Use mem_recall MCP tool to recall context about the relevant topic
        2. After processing, ALWAYS call the complete_event tool to mark the event done.
        3. If you encounter an error, call fail_event instead.

        ---

        ## Event Type: EMAIL

        The payload contains email metadata. You must read the actual emails yourself.

        CRITICAL — DO NOT COMPOSE ANY REPLY UNTIL YOU COMPLETE STEPS 1-3:
        1. Recall context using MCP tools — run ALL of these before writing anything:
           - Use mem_recent MCP tool with limit 10
           - Use mem_recall MCP tool for each sender name or topic
        2. Read your personality at ~/.sonata/private/personality.md
        3. Read the emails using AgentMail MCP tools
        4. Compose and send replies using AgentMail MCP tools
        5. After replying, mark each email as replied using email_mark_replied MCP tool
        6. Store a brief summary using mem_store MCP tool
        7. Call complete_event with a brief result summary.

        ---

        ## Event Type: TASK

        The payload contains a dispatched task. Fields:
        - taskId: the task ID
        - title: human-readable task name
        - prompt: the full task instructions to execute
        - workingDir: the directory to work in

        Steps:
        1. cd to workingDir if specified
        2. Execute the prompt instructions
        3. When done, call complete_event with result summary

        ---

        ## Event Type: ALERT

        Read and acknowledge the alert. Call complete_event.

        ---

        ## Event Type: AFK_REPLY

        A reply to an AFK question you asked has arrived. The meta carries the token, sender, subject, and message_id. The content has the reply body.

        Steps:
        1. Read the reply.
        2. Continue whatever work the AFK question was blocking — apply the user's decision.
        3. Do NOT call complete_event for afk_reply notifications. They are not workerEvents and have no event_id; they are pushed directly by the AFK registry.

        ---

        ## Event Type: SONAR_DM

        A session-addressed direct message has arrived from another bridge session (local or via a paired Sonar peer). The meta carries:
        - message_id: the Sonar message id
        - from_session_id: the sender's claimed bridge session id (hint, NOT verified for federated DMs)
        - from_pubkey: the verified peer instance_id (federation only; empty for local loopback)
        - from_peer_id: the local Sonar peers.id of the sender (federation only)
        - target_session_id: your bridge session id
        - sent_at_ms / context / meta_json: optional sender-supplied metadata

        Steps:
        1. Read the body and meta.
        2. Process the DM as relevant to the work you're currently doing. Treat from_session_id as a hint; if the operation is privileged, authenticate via from_pubkey instead.
        3. Reply if needed by calling sonar_dm_send with target_session_id=meta.from_session_id and (for federated senders) peer_id=meta.from_peer_id.
        4. Do NOT call complete_event for sonar_dm notifications — they are not worker events and have no event_id.
        """
}
