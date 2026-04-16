import Foundation
import GRDB

/// MCP JSON-RPC 2.0 handler over WebSocket.
/// Delegates to ActionRegistry — no shell-out, no per-tool switch.
final class SonataMCPHandler: @unchecked Sendable {
    private let registry: ActionRegistry
    private let dbPool: DatabasePool

    init(registry: ActionRegistry, dbPool: DatabasePool) {
        self.registry = registry
        self.dbPool = dbPool
    }

    /// Process a JSON-RPC message string. Returns response JSON or nil for notifications.
    func handleMessage(_ text: String) async -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return jsonRPCError(id: NSNull(), code: -32700, message: "Parse error")
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        // Notifications (no id) don't get responses
        guard id != nil else { return nil }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "sonata-memory", "version": "3.0.0"],
                "instructions": """
                    Sona's persistent memory system (native Swift backend). \
                    Use these tools to recall context, store learnings, read wiki pages, \
                    manage tasks, and maintain continuity across sessions.

                    Key tools:
                    - mem_recall: Primary retrieval — always try this first for context
                    - mem_wiki_read: Read compiled wiki pages for structured knowledge
                    - mem_store: Save new learnings, decisions, patterns
                    - mem_checkpoint_save/restore: Survive context compaction
                    - mem_wander: Find unexpected connections (accidental adjacency)
                    """,
            ]
            return jsonRPCResult(id: id!, result: result)

        case "tools/list":
            return jsonRPCResult(id: id!, result: ["tools": registry.mcpToolSchemas()])

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return jsonRPCError(id: id!, code: -32602, message: "Missing tool name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (success, output) = await registry.executeMCPTool(
                name: toolName, args: args, dbPool: dbPool
            )
            let content: [[String: Any]] = [["type": "text", "text": output]]
            if success {
                return jsonRPCResult(id: id!, result: ["content": content])
            } else {
                return jsonRPCResult(id: id!, result: ["content": content, "isError": true])
            }

        case "ping":
            return jsonRPCResult(id: id!, result: [:])

        case "notifications/initialized":
            return nil

        default:
            return jsonRPCError(id: id!, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - JSON-RPC Envelope Helpers

    private func jsonRPCResult(id: Any, result: Any) -> String {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id is NSNull ? NSNull() : id,
            "result": result,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return str
    }

    private func jsonRPCError(id: Any, code: Int, message: String) -> String {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id is NSNull ? NSNull() : id,
            "error": ["code": code, "message": message],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return str
    }
}
