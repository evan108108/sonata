import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/relation routes.
// Handler logic is duplicated from RelationRoutes.swift.

private let validRelationSides: Set<String> = ["memory", "entity"]

let relationActions: [SonataAction] = [

    // POST /api/relation — create (deduped)
    SonataAction(
        name: "mem_relation_create",
        description: "Create a relation between a memory/entity and another memory/entity. Deduplicates.",
        group: "/api/relation",
        path: "/",
        method: .post,
        params: [
            ActionParam("sourceId", .string, required: true, description: "Source ID"),
            ActionParam("sourceType", .string, required: true, description: "'memory' or 'entity'"),
            ActionParam("targetId", .string, required: true, description: "Target ID"),
            ActionParam("targetType", .string, required: true, description: "'memory' or 'entity'"),
            ActionParam("relation", .string, required: true, description: "Relation label"),
        ],
        handler: { ctx in
            let sourceId = try ctx.params.require("sourceId")
            let sourceType = try ctx.params.require("sourceType")
            let targetId = try ctx.params.require("targetId")
            let targetType = try ctx.params.require("targetType")
            let relation = try ctx.params.require("relation")

            guard validRelationSides.contains(sourceType) else {
                throw ActionError.invalidParam("sourceType", "must be 'memory' or 'entity'")
            }
            guard validRelationSides.contains(targetType) else {
                throw ActionError.invalidParam("targetType", "must be 'memory' or 'entity'")
            }

            let now = nowMs()

            do {
                let resultId = try await ctx.dbPool.write { db -> String in
                    let existing = try RelationRow.fetchOne(
                        db,
                        sql: """
                        SELECT * FROM relations
                        WHERE sourceId = ? AND sourceType = ? AND targetId = ? AND relation = ?
                        """,
                        arguments: [sourceId, sourceType, targetId, relation]
                    )

                    if let existing = existing {
                        return existing.id
                    }

                    let id = newUUID()
                    try db.execute(
                        sql: """
                        INSERT INTO relations (id, sourceId, sourceType, targetId, targetType, relation, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [id, sourceId, sourceType, targetId, targetType, relation, now]
                    )
                    return id
                }
                return StoreResponse(id: resultId)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/relation/list
    SonataAction(
        name: "mem_relation_list",
        description: "List relations ordered by createdAt DESC.",
        group: "/api/relation",
        path: "/list",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 200)"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 200
            do {
                let rows = try await ctx.dbPool.read { db in
                    try RelationRow.fetchAll(
                        db,
                        sql: "SELECT * FROM relations ORDER BY createdAt DESC LIMIT ?",
                        arguments: [limit]
                    )
                }
                return rows.map(relationRowToResponse)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // DELETE /api/relation?id=
    SonataAction(
        name: "mem_relation_delete",
        description: "Delete a relation by ID.",
        group: "/api/relation",
        path: "/",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Relation ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM relations WHERE id = ?", arguments: [id])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),
]
