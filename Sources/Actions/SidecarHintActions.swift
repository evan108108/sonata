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

/// Response shape for `sidecar_hint_noise` — one flag inserted.
private struct HintNoiseResponse: Encodable {
    let ok = true
    let recorded: Int
}

let sidecarHintActions: [SonataAction] = [

    // POST /api/sidecar/hint/noise — record receiver-side noise flags
    //
    // Called by the session that received a hint block after judging the
    // hints. Negative-only feedback: silence is presumed OK. Recording only
    // for now — a future recall-time join will downweight memory ids with
    // repeated flags for similar queries.
    SonataAction(
        name: "sidecar_hint_noise",
        description: """
            Flag one or more memory ids from a recently-injected hint block as noise. Called by the
            receiving Claude session (the one whose UserPromptSubmit hook popped the hint) after
            judging the block. Negative-only feedback — silence means the hint was fine. The
            optional `reason` narrows why: "self-ref" (chunk from this same session), "unrelated"
            (topically off), "stale" (dated / superseded), "recirculation" (same memory keeps
            firing). Optional `queryHash` groups flags by the query shape that produced the hint —
            leave blank if you don't have it handy.
            """,
        group: "/api/sidecar",
        path: "/hint/noise",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Session id that received the noise"),
            ActionParam("memoryIds", .string, required: true, description: "Memory ids to flag, JSON array of strings"),
            ActionParam("reason", .string, description: "Optional reason label (self-ref | unrelated | stale | recirculation | other)"),
            ActionParam("queryHash", .string, description: "Optional query-shape hash to group flags by prompt pattern"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            let idsJSON = try ctx.params.require("memoryIds")
            let reason = ctx.params.string("reason")
            let queryHash = ctx.params.string("queryHash")

            let ids: [String]
            do {
                let data = Data(idsJSON.utf8)
                ids = try JSONDecoder().decode([String].self, from: data)
            } catch {
                throw ActionError.invalidParam("memoryIds", "must be a JSON array of strings, got: \(idsJSON.prefix(80))")
            }
            let cleanIds = ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !cleanIds.isEmpty else {
                throw ActionError.invalidParam("memoryIds", "array must contain at least one non-empty id")
            }

            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    for id in cleanIds {
                        try db.execute(sql: """
                            INSERT INTO sidecarHintNoise (sessionId, memoryId, reason, queryHash, recordedAtMs)
                            VALUES (?, ?, ?, ?, ?)
                        """, arguments: [sessionId, id, reason, queryHash, now])
                    }
                }
                return HintNoiseResponse(recorded: cleanIds.count)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),


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
