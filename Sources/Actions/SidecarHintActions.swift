import Foundation
import GRDB

// MARK: - Sidecar Hint Actions (write, pop)
//
// The memory sidecar's per-request internal agent writes hints for a source
// session here (via curl — sonata-bridge MCP tools don't load into
// sub-agents). The source session's UserPromptSubmit hook pops everything
// for its sessionId in one shot and injects it into the next prompt.
// Rows are advisory ephemera: popped on read, and HealthMonitor sweeps
// anything older than 30 minutes. See the v35_sidecar_hints migration.

private struct HintWriteResponse: Encodable {
    let ok = true
    let id: Int64
}

private struct HintPopResponse: Encodable {
    let content: String
}

let sidecarHintActions: [SonataAction] = [

    // POST /api/sidecar/hint/write — store one hint block for a session
    SonataAction(
        name: "sidecar_hint_write",
        description: "Store a memory-sidecar hint block for a session. Popped by that session's next prompt-submit hook.",
        group: "/api/sidecar",
        path: "/hint/write",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Source session id the hint is for"),
            ActionParam("content", .string, required: true, description: "Hint markdown (non-empty)"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            let content = try ctx.params.require("content")
            // `require` already rejects absent/empty; also refuse
            // whitespace-only. An empty hint is noise pollution — the
            // sidecar's rule is "silence beats noise", so catch it at the
            // write side rather than have pop concatenate blank blocks.
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ActionError.invalidParam("content", "empty hint — write nothing instead")
            }
            let now = nowMs()
            do {
                let id = try await ctx.dbPool.write { db -> Int64 in
                    try db.execute(sql: """
                        INSERT INTO sidecarHints (sessionId, content, writtenAtMs)
                        VALUES (?, ?, ?)
                    """, arguments: [sessionId, content, now])
                    return db.lastInsertedRowID
                }
                return HintWriteResponse(id: id)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/sidecar/hint/pop — read-and-delete all hints for a session
    SonataAction(
        name: "sidecar_hint_pop",
        description: "Atomically read and delete all pending hints for a session. Returns them as one blob joined by blank lines, or an empty string.",
        group: "/api/sidecar",
        path: "/hint/pop",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Session id whose hints to pop"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            do {
                // Read + delete in one transaction so a concurrent write
                // lands either wholly before this pop (included) or wholly
                // after it (left for the next pop) — never dropped unread.
                let contents = try await ctx.dbPool.write { db -> [String] in
                    let rows = try String.fetchAll(db, sql: """
                        SELECT content FROM sidecarHints
                        WHERE sessionId = ?
                        ORDER BY writtenAtMs ASC
                    """, arguments: [sessionId])
                    try db.execute(sql: """
                        DELETE FROM sidecarHints WHERE sessionId = ?
                    """, arguments: [sessionId])
                    return rows
                }
                return HintPopResponse(content: contents.joined(separator: "\n\n"))
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
