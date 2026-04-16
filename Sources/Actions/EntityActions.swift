import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/entity routes.
// Handler logic is duplicated from EntityRoutes.swift.

private func encodeAnyJSON(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
          let str = String(data: data, encoding: .utf8) else {
        return nil
    }
    return str
}

let entityActions: [SonataAction] = [

    // POST /api/entity — upsert by name
    SonataAction(
        name: "mem_entity_upsert",
        description: "Upsert an entity by name. Creates if new, updates if existing.",
        group: "/api/entity",
        path: "/",
        method: .post,
        params: [
            ActionParam("name", .string, required: true, description: "Entity name (unique key)"),
            ActionParam("type", .string, required: true, description: "Entity type"),
            ActionParam("description", .string, required: true, description: "Entity description"),
            ActionParam("attributes", .object, description: "Arbitrary JSON attributes"),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            let type = try ctx.params.require("type")
            let description = try ctx.params.require("description")
            let attributesJSON: String? = ctx.params.object("attributes").flatMap { encodeAnyJSON($0) }

            let now = nowMs()

            do {
                let resultId = try await ctx.dbPool.write { db -> String in
                    let existing = try EntityRow.fetchOne(
                        db,
                        sql: "SELECT * FROM entities WHERE name = ?",
                        arguments: [name]
                    )

                    if let existing = existing {
                        try db.execute(
                            sql: """
                            UPDATE entities
                            SET type = ?, description = ?, attributes = COALESCE(?, attributes), updatedAt = ?
                            WHERE id = ?
                            """,
                            arguments: [type, description, attributesJSON, now, existing.id]
                        )
                        return existing.id
                    } else {
                        let id = newUUID()
                        try db.execute(
                            sql: """
                            INSERT INTO entities (id, name, type, description, attributes, referenceCount, createdAt, updatedAt)
                            VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                            """,
                            arguments: [id, name, type, description, attributesJSON, now, now]
                        )
                        return id
                    }
                }
                return StoreResponse(id: resultId)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/entity/search?q=
    SonataAction(
        name: "mem_entity_search",
        description: "Full-text search on entities (FTS5).",
        group: "/api/entity",
        path: "/search",
        method: .get,
        params: [
            ActionParam("q", .string, required: true, description: "FTS5 query string"),
            ActionParam("limit", .integer, description: "Max results (default 10)"),
            ActionParam("type", .string, description: "Filter by entity type"),
        ],
        handler: { ctx in
            let q = try ctx.params.require("q")
            let limit = ctx.params.int("limit") ?? 10
            let type = ctx.params.string("type")

            var sql = """
                SELECT e.* FROM entities e
                JOIN entities_fts fts ON fts.rowid = e.rowid
                WHERE entities_fts MATCH ?
            """
            var args: [any DatabaseValueConvertible] = [q]

            if let t = type {
                sql += " AND e.type = ?"
                args.append(t)
            }
            sql += " ORDER BY rank LIMIT ?"
            args.append(limit)

            do {
                let rows = try await ctx.dbPool.read { db in
                    try EntityRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(entityRowToResponse)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/entity/get?id=
    SonataAction(
        name: "mem_entity_get",
        description: "Get an entity by ID.",
        group: "/api/entity",
        path: "/get",
        method: .get,
        params: [
            ActionParam("id", .string, required: true, description: "Entity ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                let row = try await ctx.dbPool.read { db in
                    try EntityRow.fetchOne(db, sql: "SELECT * FROM entities WHERE id = ?", arguments: [id])
                }
                guard let row else {
                    throw ActionError.notFound("Entity not found")
                }
                return entityRowToResponse(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/entity/list
    SonataAction(
        name: "mem_entity_list",
        description: "List entities ordered by updatedAt DESC.",
        group: "/api/entity",
        path: "/list",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 50)"),
            ActionParam("type", .string, description: "Filter by entity type"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 50
            let type = ctx.params.string("type")

            var sql = "SELECT * FROM entities"
            var args: [any DatabaseValueConvertible] = []

            if let t = type {
                sql += " WHERE type = ?"
                args.append(t)
            }
            sql += " ORDER BY updatedAt DESC LIMIT ?"
            args.append(limit)

            do {
                let rows = try await ctx.dbPool.read { db in
                    try EntityRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(entityRowToResponse)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/entity/relations?id=&type=
    SonataAction(
        name: "mem_entity_relations",
        description: "Get incoming and outgoing relations for an entity or memory.",
        group: "/api/entity",
        path: "/relations",
        method: .get,
        params: [
            ActionParam("id", .string, required: true, description: "Entity or memory ID"),
            ActionParam("type", .string, description: "'entity' (default) or 'memory'"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let type = ctx.params.string("type") ?? "entity"

            do {
                let rows = try await ctx.dbPool.read { db -> [RelationRow] in
                    let outgoing = try RelationRow.fetchAll(
                        db,
                        sql: "SELECT * FROM relations WHERE sourceId = ? AND sourceType = ?",
                        arguments: [id, type]
                    )
                    let incoming = try RelationRow.fetchAll(
                        db,
                        sql: "SELECT * FROM relations WHERE targetId = ? AND targetType = ?",
                        arguments: [id, type]
                    )
                    return outgoing + incoming
                }
                return rows.map(relationRowToResponse)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/entity?name=
    SonataAction(
        name: "mem_entity_by_name",
        description: "Get an entity by name.",
        group: "/api/entity",
        path: "/",
        method: .get,
        params: [
            ActionParam("name", .string, required: true, description: "Entity name"),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            do {
                let row = try await ctx.dbPool.read { db in
                    try EntityRow.fetchOne(db, sql: "SELECT * FROM entities WHERE name = ?", arguments: [name])
                }
                guard let row else {
                    throw ActionError.notFound("Entity not found")
                }
                return entityRowToResponse(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // PATCH /api/entity
    SonataAction(
        name: "mem_entity_patch",
        description: "Update an entity by ID.",
        group: "/api/entity",
        path: "/",
        method: .patch,
        params: [
            ActionParam("id", .string, required: true, description: "Entity ID"),
            ActionParam("name", .string, description: "New name"),
            ActionParam("type", .string, description: "New type"),
            ActionParam("description", .string, description: "New description"),
            ActionParam("attributes", .object, description: "New attributes (object)"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            var setClauses: [String] = ["updatedAt = ?"]
            var args: [any DatabaseValueConvertible] = [now]

            if let v = ctx.params.string("name")        { setClauses.append("name = ?");        args.append(v) }
            if let v = ctx.params.string("type")        { setClauses.append("type = ?");        args.append(v) }
            if let v = ctx.params.string("description") { setClauses.append("description = ?"); args.append(v) }
            if let attrs = ctx.params.object("attributes"), let json = encodeAnyJSON(attrs) {
                setClauses.append("attributes = ?")
                args.append(json)
            }

            args.append(id)
            let sql = "UPDATE entities SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: sql, arguments: StatementArguments(args))
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return PatchResponse(id: id)
        }
    ),

    // DELETE /api/entity?id=
    SonataAction(
        name: "mem_entity_delete",
        description: "Delete an entity by ID.",
        group: "/api/entity",
        path: "/",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Entity ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM entities WHERE id = ?", arguments: [id])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/entity/touch
    SonataAction(
        name: "mem_entity_touch",
        description: "Increment referenceCount and set lastReferencedAt for an entity by id or name.",
        group: "/api/entity",
        path: "/touch",
        method: .post,
        params: [
            ActionParam("id", .string, description: "Entity ID (use either id or name)"),
            ActionParam("name", .string, description: "Entity name (use either id or name)"),
        ],
        handler: { ctx in
            let id = ctx.params.string("id")
            let name = ctx.params.string("name")
            let now = nowMs()

            do {
                let resultId: String? = try await ctx.dbPool.write { db -> String? in
                    if let name = name, !name.isEmpty {
                        let row = try EntityRow.fetchOne(
                            db,
                            sql: "SELECT * FROM entities WHERE name = ?",
                            arguments: [name]
                        )
                        guard let row else { return nil }
                        try db.execute(
                            sql: """
                            UPDATE entities
                            SET referenceCount = referenceCount + 1,
                                lastReferencedAt = ?,
                                updatedAt = ?
                            WHERE id = ?
                            """,
                            arguments: [now, now, row.id]
                        )
                        return row.id
                    } else if let id = id, !id.isEmpty {
                        let row = try EntityRow.fetchOne(
                            db,
                            sql: "SELECT * FROM entities WHERE id = ?",
                            arguments: [id]
                        )
                        guard let row else { return nil }
                        try db.execute(
                            sql: """
                            UPDATE entities
                            SET referenceCount = referenceCount + 1,
                                lastReferencedAt = ?,
                                updatedAt = ?
                            WHERE id = ?
                            """,
                            arguments: [now, now, row.id]
                        )
                        return row.id
                    }
                    return nil
                }
                return TouchEntityResponse(id: resultId, success: resultId != nil)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
