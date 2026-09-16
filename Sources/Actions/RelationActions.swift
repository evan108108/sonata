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

            let result: Result<String, ActionError>
            do {
                result = try await ctx.dbPool.write { db -> Result<String, ActionError> in
                    let existing = try RelationRow.fetchOne(
                        db,
                        sql: """
                        SELECT * FROM relations
                        WHERE sourceId = ? AND sourceType = ? AND targetId = ? AND relation = ?
                        """,
                        arguments: [sourceId, sourceType, targetId, relation]
                    )

                    if let existing = existing {
                        return .success(existing.id)
                    }

                    // Emit-side existence check: refuse writes that would create
                    // a dangling edge (target/source id doesn't resolve to a row
                    // in the named table). Before this check, a truncated or
                    // typo'd id was silently accepted and returned success:true,
                    // creating an edge that never fires in graph recall. See
                    // learning db6c0952 (2026-07-28) and 6d43323c (2026-07-19)
                    // for the two prior live instances, and the 2026-09-16
                    // task that landed this check for the third.
                    if !relationEndpointExists(db: db, id: sourceId, type: sourceType) {
                        return .failure(.notFound(
                            "sourceId '\(sourceId)' does not resolve to a \(sourceType) row (dangling_source)"
                        ))
                    }
                    if !relationEndpointExists(db: db, id: targetId, type: targetType) {
                        return .failure(.notFound(
                            "targetId '\(targetId)' does not resolve to a \(targetType) row (dangling_target)"
                        ))
                    }

                    let id = newUUID()
                    try db.execute(
                        sql: """
                        INSERT INTO relations (id, sourceId, sourceType, targetId, targetType, relation, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [id, sourceId, sourceType, targetId, targetType, relation, now]
                    )
                    return .success(id)
                }
            } catch let error as ActionError {
                throw error
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            switch result {
            case .success(let id):
                return StoreResponse(id: id)
            case .failure(let err):
                throw err
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
            let deleted: Bool
            do {
                deleted = try await ctx.dbPool.write { db -> Bool in
                    // Existence-before-delete so a bogus id gets a distinct
                    // 404 instead of the same success:true a real delete
                    // returns — the symmetric emit-side ⊥ for the create
                    // handler above.
                    let hit = try Int.fetchOne(
                        db,
                        sql: "SELECT 1 FROM relations WHERE id = ? LIMIT 1",
                        arguments: [id]
                    )
                    guard hit != nil else { return false }
                    try db.execute(sql: "DELETE FROM relations WHERE id = ?", arguments: [id])
                    return true
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            guard deleted else {
                throw ActionError.notFound("relation '\(id)' does not exist")
            }
            return SuccessResponse()
        }
    ),
]

// MARK: - Endpoint existence check
//
// Returns true when `id` names an existing row in the table implied by `type`
// ("memory" -> memories, "entity" -> entities). Ignores status (an archived
// memory is not a dangling target). Kept file-private and pure so the create
// handler and the test can both call it. See db6c0952, 6d43323c.
func relationEndpointExists(db: GRDB.Database, id: String, type: String) -> Bool {
    let sql: String
    switch type {
    case "memory":
        sql = "SELECT 1 FROM memories WHERE id = ? LIMIT 1"
    case "entity":
        sql = "SELECT 1 FROM entities WHERE id = ? LIMIT 1"
    default:
        return false
    }
    do {
        return try Int.fetchOne(db, sql: sql, arguments: [id]) != nil
    } catch {
        return false
    }
}
