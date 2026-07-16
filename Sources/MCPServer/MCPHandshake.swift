import Foundation
import GRDB

/// Stateless MCP JSON-RPC handler — no per-connection state lives on an
/// actor. The four
/// values that used to be actor-held (sessionKey, role, protocol version,
/// tool schema cache) are now: (a) function parameters, (b) recomputed from
/// DB per call, (c) a shared static constant, (d) also a shared static
/// (tool schemas are process-wide).
enum MCPHandshake {
    private static let protocolVersion = "2025-03-26"

    /// Handles a single JSON-RPC method call. Returns the response JSON
    /// string, or nil if the method is a notification (no response expected).
    static func handle(
        method: String,
        id: Any?,
        params: [String: Any],
        sessionKey: String,
        role: SessionRole,
        actionRegistry: ActionRegistry,
        dbPool: DatabasePool
    ) async -> String? {
        switch method {
        case "initialize":
            return await handleInitialize(id: id, sessionKey: sessionKey, role: role, dbPool: dbPool)
        case "notifications/initialized":
            return nil   // notification, no response
        case "tools/list":
            return handleToolsList(id: id, actionRegistry: actionRegistry)
        case "tools/call":
            return await handleToolsCall(
                id: id, params: params,
                sessionKey: sessionKey, role: role,
                actionRegistry: actionRegistry, dbPool: dbPool
            )
        default:
            return jsonRPCErrorResult(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Resolve the human-readable label for this session so the identity
    /// preamble in `workerInstructions` shows the correct sessionLabel
    /// (e.g. "sona-worker-3") rather than the raw sessionKey. Called during
    /// handshake — the ~10ms DB read is well within the handshake budget.
    private static func lookupSessionLabel(
        sessionKey: String, role: SessionRole, dbPool: DatabasePool
    ) async -> String? {
        switch role {
        case .supervisor:
            return "supervisor"
        case .worker:
            return try? await dbPool.read { db in
                try String.fetchOne(db, sql:
                    "SELECT sessionLabel FROM workers WHERE workerId = ?",
                    arguments: [sessionKey])
            }.flatMap { $0 }
        case .interactive:
            return try? await dbPool.read { db in
                try String.fetchOne(db, sql: """
                    SELECT name FROM interactiveSessions
                    WHERE ('session-' || SUBSTR(REPLACE(sessionId, '-', ''), 1, 16)) = ?
                """, arguments: [sessionKey])
            }.flatMap { $0 }
        }
    }

    private static func handleInitialize(
        id: Any?, sessionKey: String, role: SessionRole, dbPool: DatabasePool
    ) async -> String {
        let sessionLabel = await lookupSessionLabel(
            sessionKey: sessionKey, role: role, dbPool: dbPool
        )
        let instructions = MCPInstructionsBody.build(
            role: role, sessionKey: sessionKey, sessionLabel: sessionLabel
        )
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [
                "tools": ["listChanged": true],
                "experimental": ["claude/channel": [:]],
            ],
            "serverInfo": [
                "name": "sonata-bridge",
                "version": "1.0.0",
            ],
            "instructions": instructions,
        ]
        return jsonRPCResult(id: id, result: result)
    }

    private static func handleToolsList(id: Any?, actionRegistry: ActionRegistry) -> String {
        let tools = mergedToolSchemas(actionRegistry: actionRegistry)
        return jsonRPCResult(id: id, result: ["tools": tools])
    }

    /// Merge the worker-transport's narrow shim schemas with the full
    /// ActionRegistry surface, narrow taking precedence on name collision.
    /// Stable order — narrow first in declaration order, then registry
    /// alphabetical — keeps `tools/list` responses prompt-cache friendly.
    /// See plan: mcp-unify-worker-surface.md § Step 1.
    private static func mergedToolSchemas(actionRegistry: ActionRegistry) -> [[String: Any]] {
        var byName: [String: [String: Any]] = [:]
        for schema in actionRegistry.mcpToolSchemas() {
            if let name = schema["name"] as? String {
                byName[name] = schema
            }
        }
        for schema in MCPToolSchemas.all {
            if let name = schema["name"] as? String {
                byName[name] = schema
            }
        }
        let narrowNames = MCPToolSchemas.all.compactMap { $0["name"] as? String }
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for n in narrowNames {
            if let s = byName[n] { out.append(s); seen.insert(n) }
        }
        for (name, schema) in byName.sorted(by: { $0.key < $1.key }) where !seen.contains(name) {
            out.append(schema)
        }
        return out
    }

    private static func handleToolsCall(
        id: Any?, params: [String: Any],
        sessionKey: String, role: SessionRole,
        actionRegistry: ActionRegistry, dbPool: DatabasePool
    ) async -> String {
        guard let toolName = params["name"] as? String else {
            return jsonRPCErrorResult(id: id, code: -32602, message: "Missing tool name")
        }

        // Distinguish absent / null / empty-object / populated for the
        // server-note diagnostic below. `args` (coerced to `[:]`) collapses
        // those cases, so we compute this from the RAW value before coercion.
        let rawArguments = params["arguments"]
        let argsShape: String
        switch rawArguments {
        case nil:
            argsShape = "absent"
        case is NSNull:
            argsShape = "null"
        case let dict as [String: Any]:
            argsShape = dict.isEmpty ? "empty-object" : "populated"
        default:
            argsShape = "wrong-type"
        }
        let args = rawArguments as? [String: Any] ?? [:]

        // Worker tool-denial check. Only enforced
        // for worker sessions; supervisor/interactive can use any registered
        // tool. If the tool is on this worker's denylist, refuse WITHOUT
        // dispatching so plugin/handler code never sees the call.
        if role == .worker,
           await MCPToolHandlers.checkToolDenial(workerId: sessionKey, toolName: toolName, dbPool: dbPool) {
            let content: [[String: Any]] = [[
                "type": "text",
                "text": "Tool '\(toolName)' is not allowed for this worker (workerToolDenials).",
            ]]
            return jsonRPCResult(id: id, result: [
                "content": content, "isError": true,
            ])
        }

        let (success, output) = await MCPToolHandlers.handle(
            toolName: toolName, args: args,
            role: role, sessionKey: sessionKey,
            actionRegistry: actionRegistry, dbPool: dbPool
        )

        // Server note on missing-required-parameter failures. Ported forward
        // from the pre-ecfb094 MCPSessionState.handleToolsCall (originally
        // corrected in 616305e "flip empty-args server note (was nudging
        // workers into REST shim)"). The correct diagnosis was collateral
        // damage when MCPSessionState was eradicated; workers spent weeks
        // seeing the bare "Missing required parameter" error with no
        // steering, which sent them chasing whichever contradictory memory
        // they recalled first. Do NOT delete this without also updating
        // MCPToolCallTests.testEmptyArgsServerNote* — those tests exist so
        // the next type-eradication refactor can't silently remove it again.
        var finalOutput = output
        if !success, output.contains("Missing required parameter") {
            switch argsShape {
            case "empty-object":
                finalOutput += "\n\n[server note] You sent `params.arguments = {}` "
                    + "for tool '\(toolName)' — an empty object. The arguments "
                    + "were NOT dropped in transit; they were never in your "
                    + "request. This is a model-output issue. Re-emit the "
                    + "tool call with a populated arguments object. Do NOT "
                    + "fall back to a REST shim — the MCP transport is fine."
            case "absent", "null":
                finalOutput += "\n\n[server note] `params.arguments` was "
                    + "\(argsShape) in your tools/call for '\(toolName)'. "
                    + "The field is required by the JSON-RPC envelope; "
                    + "either your client stripped it or you emitted a "
                    + "malformed envelope. Retry the call; if it persists, "
                    + "the MCP client is dropping arguments."
            default:
                break
            }
        }

        let content: [[String: Any]] = [["type": "text", "text": finalOutput]]
        let result: [String: Any] = [
            "content": content,
            "isError": !success,
        ]
        return jsonRPCResult(id: id, result: result)
    }

    // MARK: - JSON-RPC envelope helpers

    static func jsonRPCResult(id: Any?, result: [String: Any]) -> String {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id { envelope["id"] = id }
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func jsonRPCErrorResult(id: Any?, code: Int, message: String) -> String {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id { envelope["id"] = id } else { envelope["id"] = NSNull() }
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// The workerInstructions text lives in MCPInstructionsBody (Section E).
// handleInitialize above calls MCPInstructionsBody.build(...) directly.
