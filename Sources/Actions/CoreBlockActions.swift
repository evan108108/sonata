import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/core routes.
// Handler logic duplicated from CoreBlockRoutes.swift.

private func coreBlockRowToResponseForAction(_ row: CoreBlockRow) -> CoreBlockResponse {
    CoreBlockResponse(
        _id: row.id,
        key: row.key,
        category: row.category,
        content: row.content,
        priority: row.priority,
        updatedAt: row.updatedAt,
        active: row.active,
        compressed: row.compressed
    )
}

let coreBlockActions: [SonataAction] = [

    // GET /api/core/list — list active blocks
    SonataAction(
        name: "mem_core_list",
        description: "List core blocks, ordered by priority DESC then key ASC.",
        group: "/api/core",
        path: "/list",
        method: .get,
        params: [
            ActionParam("category", .string, description: "Filter by category"),
            ActionParam("all", .string, description: "If 'true', include inactive blocks"),
        ],
        handler: { ctx in
            let category = ctx.params.string("category")
            let includeInactive = ctx.params.string("all") == "true"

            var sql = "SELECT * FROM coreBlocks WHERE 1=1"
            var args: [any DatabaseValueConvertible] = []

            if !includeInactive {
                sql += " AND active = 1"
            }
            if let cat = category {
                sql += " AND category = ?"
                args.append(cat)
            }
            sql += " ORDER BY priority DESC, key ASC"

            do {
                let rows = try ctx.dbPool.read { db in
                    try CoreBlockRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(coreBlockRowToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/core/get?key= — get by key
    SonataAction(
        name: "mem_core_get",
        description: "Get a core block by key.",
        group: "/api/core",
        path: "/get",
        method: .get,
        params: [
            ActionParam("key", .string, required: true, description: "Core block key"),
        ],
        handler: { ctx in
            let key = try ctx.params.require("key")
            do {
                let row = try await ctx.dbPool.read { db in
                    try CoreBlockRow.fetchOne(db, sql: "SELECT * FROM coreBlocks WHERE key = ?", arguments: [key])
                }
                guard let row else {
                    throw ActionError.notFound("Core block not found")
                }
                return coreBlockRowToResponseForAction(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/core — upsert by key
    SonataAction(
        name: "mem_core_set",
        description: "Upsert a core block by key.",
        group: "/api/core",
        path: "/",
        method: .post,
        params: [
            ActionParam("key", .string, required: true, description: "Core block key"),
            ActionParam("category", .string, required: true, description: "Category"),
            ActionParam("content", .string, required: true, description: "Block content"),
            ActionParam("priority", .integer, description: "Priority (default 0)"),
            ActionParam("compressed", .string, description: "Compressed representation"),
        ],
        handler: { ctx in
            let key = try ctx.params.require("key")
            let category = try ctx.params.require("category")
            let content = try ctx.params.require("content")
            let priority = ctx.params.int("priority") ?? 0
            let compressed = ctx.params.string("compressed")

            let now = nowMs()

            do {
                let id = try await ctx.dbPool.write { db -> String in
                    let existing = try CoreBlockRow.fetchOne(
                        db, sql: "SELECT * FROM coreBlocks WHERE key = ?", arguments: [key])

                    if let existing {
                        try db.execute(
                            sql: """
                            UPDATE coreBlocks SET
                                category = ?, content = ?, priority = ?,
                                compressed = ?, active = 1, updatedAt = ?
                            WHERE id = ?
                            """,
                            arguments: [
                                category, content, priority,
                                compressed, now, existing.id
                            ]
                        )
                        return existing.id
                    } else {
                        let id = newUUID()
                        try db.execute(
                            sql: """
                            INSERT INTO coreBlocks
                                (id, key, category, content, priority, updatedAt, active, compressed)
                            VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                            """,
                            arguments: [
                                id, key, category, content,
                                priority, now, compressed
                            ]
                        )
                        return id
                    }
                }
                return StoreResponse(id: id)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/core/deactivate?key= — set active=false
    SonataAction(
        name: "core_deactivate",
        description: "Deactivate a core block by key (sets active=0).",
        group: "/api/core",
        path: "/deactivate",
        method: .post,
        params: [
            ActionParam("key", .string, required: true, description: "Core block key", source: .query),
        ],
        handler: { ctx in
            let key = try ctx.params.require("key")
            let now = nowMs()

            do {
                let changed = try await ctx.dbPool.write { db -> Int in
                    try db.execute(
                        sql: "UPDATE coreBlocks SET active = 0, updatedAt = ? WHERE key = ?",
                        arguments: [now, key]
                    )
                    return db.changesCount
                }
                guard changed > 0 else {
                    throw ActionError.notFound("Core block not found")
                }
                return SuccessResponse()
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
