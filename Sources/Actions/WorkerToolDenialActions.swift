import Foundation
import GRDB

// Settings-driven tool denylist for the HTTP MCP transport. Backed by the
// `workerToolDenials` table (migration v13). The runtime check lives in
// MCPSessionState.checkToolDenial — it reads from this table on every
// tools/call and short-circuits a denied tool with isError before reaching
// ActionRegistry.executeMCPTool. Default empty: every tool callable.
//
// IMPORTANT — this is a UI convenience knob, NOT a security boundary.
// REST callers of /api/mcp/call bypass the gate entirely. The Settings
// banner must say so. See plan mcp-unify-worker-surface.md § Surface
// alignment for the reasoning.

private struct WorkerToolDenialRow: FetchableRecord, Codable {
    var toolName: String
    var appliesTo: String
    var reason: String?
    var addedAt: Int64
    var addedBy: String?
}

private struct WorkerToolDenialResponse: Encodable {
    let toolName: String
    let appliesTo: String
    let reason: String?
    let addedAt: Int64
    let addedBy: String?
}

let workerToolDenialActions: [SonataAction] = [

    // GET /api/worker/tool-denials — list every row
    SonataAction(
        name: "worker_tool_denials_list",
        description: "List every entry in workerToolDenials (default empty).",
        group: "/api/worker",
        path: "/tool-denials",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows: [WorkerToolDenialRow] = try ctx.dbPool.read { db in
                    try WorkerToolDenialRow.fetchAll(db,
                        sql: "SELECT toolName, appliesTo, reason, addedAt, addedBy FROM workerToolDenials ORDER BY toolName ASC")
                }
                return rows.map { r in
                    WorkerToolDenialResponse(
                        toolName: r.toolName,
                        appliesTo: r.appliesTo,
                        reason: r.reason,
                        addedAt: r.addedAt,
                        addedBy: r.addedBy
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/worker/tool-deny — upsert a deny row
    SonataAction(
        name: "worker_tool_deny",
        description: "Deny a tool name for one or more roles. appliesTo is a comma-separated subset of {worker, interactive, supervisor}; defaults to 'worker'.",
        group: "/api/worker",
        path: "/tool-deny",
        method: .post,
        params: [
            ActionParam("toolName", .string, required: true, description: "Tool name to deny (must exist in ActionRegistry — not validated server-side, a typo just means a row that matches nothing)"),
            ActionParam("appliesTo", .string, description: "Comma-separated roles (default 'worker'). Accepted tokens: worker, interactive, supervisor."),
            ActionParam("reason", .string, description: "Optional human-readable reason shown in the UI and in deny responses"),
        ],
        handler: { ctx in
            let toolName = try ctx.params.require("toolName")
            let appliesToRaw = ctx.params.string("appliesTo") ?? "worker"
            // Validate role tokens
            let validRoles: Set<String> = ["worker", "interactive", "supervisor"]
            let tokens = appliesToRaw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else {
                throw ActionError.invalidParam("appliesTo", "must contain at least one role")
            }
            for tok in tokens where !validRoles.contains(tok) {
                throw ActionError.invalidParam("appliesTo", "unknown role '\(tok)'")
            }
            let canonicalAppliesTo = tokens.sorted().joined(separator: ",")
            let reason = ctx.params.string("reason")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: """
                        INSERT INTO workerToolDenials (toolName, appliesTo, reason, addedAt, addedBy)
                        VALUES (?, ?, ?, ?, 'user')
                        ON CONFLICT(toolName) DO UPDATE SET
                            appliesTo = excluded.appliesTo,
                            reason = excluded.reason,
                            addedAt = excluded.addedAt,
                            addedBy = excluded.addedBy
                        """, arguments: [toolName, canonicalAppliesTo, reason, now])
                }
                return SuccessResponse()
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/worker/tool-allow — remove a deny row
    SonataAction(
        name: "worker_tool_allow",
        description: "Remove a tool name from the deny list (no-op if not present).",
        group: "/api/worker",
        path: "/tool-allow",
        method: .post,
        params: [
            ActionParam("toolName", .string, required: true, description: "Tool name to allow"),
        ],
        handler: { ctx in
            let toolName = try ctx.params.require("toolName")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM workerToolDenials WHERE toolName = ?", arguments: [toolName])
                }
                return SuccessResponse()
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
