import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/entity routes.
// Handler logic is duplicated from EntityRoutes.swift.

private func encodeAnyJSON(_ value: Any) -> String? {
    // SafeJSON guards against a scalar top-level, which would otherwise raise
    // an uncatchable NSException and crash the process. Callers currently pass
    // `.object(...)` dicts, but the `Any` signature must not be a landmine.
    guard let data = SafeJSON.data(withJSONObject: value, options: []),
          let str = String(data: data, encoding: .utf8) else {
        return nil
    }
    return str
}

/// mem_entity_upsert's result. `id` alone was not enough to tell a caller what
/// happened — `success: true` looked identical whether the write landed on the
/// row they named, a fork of it, or a brand new row. `created` and `matchedBy`
/// make the target explicit, and `warnings` reports a forked name that the
/// caller resolved unambiguously but should still know about.
struct EntityUpsertResponse: Encodable {
    let id: String
    let success = true
    let created: Bool
    /// `id` | `name+type` | `created`
    let matchedBy: String
    let warnings: [String]?
}

let entityActions: [SonataAction] = [

    // POST /api/entity — upsert by (name, type), or by id
    //
    // This door used to match on `WHERE name = ?` and ignore its own `type`
    // argument entirely, which made it silently destructive: upsert(name:"Sona",
    // type:"agent", description:…) returned the id of the CANONICAL Sona/person
    // row (1035 edges) and overwrote its description and type. Once a name was
    // forked, the fork could never be addressed through here at all — the name
    // always resolved to whichever row came back first, while the caller
    // believed they were editing the one they named.
    //
    // Now: the `type` argument participates in matching (via the shared
    // resolver in EntityIdentity.swift, so this door and the mem_store
    // annotation door agree), and a name that resolves to no row of the named
    // type is a 409 naming the ids — never a silent write to a row the caller
    // did not name. `id` is the escape hatch that can address any specific row,
    // including changing its type.
    SonataAction(
        name: "mem_entity_upsert",
        description: """
            Upsert an entity, matched on (name, type). Creates if new, updates if existing.

            Matching is case-insensitive and considers BOTH name and type. If the name exists but only under a DIFFERENT type, this errors (409) and names the conflicting rows rather than overwriting one of them — pass `id` to target a specific row (that is also how you change an existing entity's type), or use mem_entity_patch.
            """,
        group: "/api/entity",
        path: "/",
        method: .post,
        params: [
            ActionParam("name", .string, required: true, description: "Entity name (matched case-insensitively, together with type)"),
            ActionParam("type", .string, required: true, description: "Entity type (participates in matching — a mismatch is an error, not an overwrite)"),
            ActionParam("description", .string, required: true, description: "Entity description"),
            ActionParam("attributes", .object, description: "Arbitrary JSON attributes"),
            ActionParam("id", .string, description: "Target a specific entity row by id, bypassing name/type matching. Required to disambiguate a forked name, and the only way to change an existing entity's type."),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            let type = try ctx.params.require("type")
            let description = try ctx.params.require("description")
            let attributesJSON: String? = ctx.params.object("attributes").flatMap { encodeAnyJSON($0) }
            let targetId = ctx.params.string("id").flatMap { $0.isEmpty ? nil : $0 }

            let now = nowMs()

            // Two shapes: an id-targeted write takes the caller's `name`
            // verbatim (they named the row, they may rename it), while a
            // name-matched write leaves the stored spelling alone — matching is
            // case-insensitive, and normalizing `evenflow` to `Evenflow`
            // because of one caller's casing is a rename nobody asked for.
            let updateById = """
                UPDATE entities
                SET name = ?, type = ?, description = ?, attributes = COALESCE(?, attributes), updatedAt = ?
                WHERE id = ?
                """
            let updateMatched = """
                UPDATE entities
                SET type = ?, description = ?, attributes = COALESCE(?, attributes), updatedAt = ?
                WHERE id = ?
                """

            do {
                let result = try await ctx.dbPool.write { db -> EntityUpsertResponse in
                    // Explicit id — address exactly this row, whatever it holds.
                    if let targetId {
                        guard try Row.fetchOne(
                            db,
                            sql: "SELECT id FROM entities WHERE id = ?",
                            arguments: [targetId]
                        ) != nil else {
                            throw ActionError.notFound("Entity id '\(targetId)'")
                        }
                        try db.execute(
                            sql: updateById,
                            arguments: [name, type, description, attributesJSON, now, targetId]
                        )
                        return EntityUpsertResponse(id: targetId, created: false, matchedBy: "id", warnings: nil)
                    }

                    switch try resolveEntity(db, name: name, type: type) {
                    case .absent:
                        let id = newUUID()
                        try db.execute(
                            sql: """
                            INSERT INTO entities (id, name, type, description, attributes, referenceCount, createdAt, updatedAt)
                            VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                            """,
                            arguments: [id, name, type, description, attributesJSON, now, now]
                        )
                        return EntityUpsertResponse(id: id, created: true, matchedBy: "created", warnings: nil)

                    case .matched(let target, let siblings):
                        try db.execute(
                            sql: updateMatched,
                            arguments: [type, description, attributesJSON, now, target.id]
                        )
                        // Unambiguous — the type picked the row — but the caller
                        // should know the name is forked, because every
                        // name-only door (relations, by-name lookup) will resolve
                        // it to the most-connected row, not necessarily this one.
                        let warnings = siblings.isEmpty ? nil : [
                            "Name '\(name)' is forked across \(siblings.count + 1) rows; matched \(target.label) on type. Others: \(siblings.map(\.label).joined(separator: ", "))."
                        ]
                        return EntityUpsertResponse(id: target.id, created: false, matchedBy: "name+type", warnings: warnings)

                    case .typeMismatch(let candidates):
                        // The old behavior was to overwrite candidates.first here
                        // and return success:true. That is the bug.
                        throw ActionError.custom(
                            """
                            Entity '\(name)' exists, but not with type '\(type)'. \
                            Refusing to overwrite a row you did not name. \
                            Existing: \(candidates.map(\.label).joined(separator: ", ")). \
                            Pass `id` to target one of these explicitly (this is also how you change an entity's type), \
                            or use a distinct name.
                            """,
                            .conflict
                        )
                    }
                }
                return result
            } catch let e as ActionError {
                throw e
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

            let ftsQuery = ftsEscape(q)
            guard !ftsQuery.isEmpty else { return [EntityResponse]() }

            var sql = """
                SELECT e.* FROM entities e
                JOIN entities_fts fts ON fts.rowid = e.rowid
                WHERE entities_fts MATCH ?
            """
            var args: [any DatabaseValueConvertible] = [ftsQuery]

            if let t = type {
                sql += " AND e.type = ?"
                args.append(t)
            }
            sql += " ORDER BY rank LIMIT ?"
            args.append(limit)

            do {
                let rows = try ctx.dbPool.read { db in
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
                let rows = try ctx.dbPool.read { db in
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
    //
    // Callers use this to check an entity's stored `type` BEFORE annotating, so
    // handing back an arbitrary row of a forked name is what causes the next
    // fork. Resolves through the shared rule: case-insensitive, most-connected
    // row wins, ordering total.
    SonataAction(
        name: "mem_entity_by_name",
        description: "Get an entity by name (case-insensitive). If the name is forked across several rows, returns the most-connected one — use mem_entity_search or mem_entity_list to see the rest.",
        group: "/api/entity",
        path: "/",
        method: .get,
        params: [
            ActionParam("name", .string, required: true, description: "Entity name"),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            do {
                let row = try await ctx.dbPool.read { db -> EntityRow? in
                    guard let candidate = try resolveEntityByName(db, name: name) else { return nil }
                    return try EntityRow.fetchOne(
                        db,
                        sql: "SELECT * FROM entities WHERE id = ?",
                        arguments: [candidate.id]
                    )
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
    //
    // Partial update by id. Top-level scalar fields (name/type/description) overwrite.
    // The `attributes` field uses RFC 7396 JSON Merge Patch semantics via SQLite's
    // json_patch():
    //   - keys present in the patch overwrite the target,
    //   - keys absent from the patch are preserved,
    //   - a key set to JSON null in the patch deletes that key from the target.
    // Empty `attributes: {}` is a no-op against existing attributes.
    // Plugin helpers (memory-client.ts) and HTTP convention both expect merge,
    // not replace — full-replace was a long-standing bug that wiped sibling keys
    // on every partial PATCH (sonata-studio T9 diagnosis).
    SonataAction(
        name: "mem_entity_patch",
        description: "Update an entity by ID. `attributes` merges via RFC 7396 (json_patch); null deletes a key.",
        group: "/api/entity",
        path: "/",
        method: .patch,
        params: [
            ActionParam("id", .string, required: true, description: "Entity ID"),
            ActionParam("name", .string, description: "New name"),
            ActionParam("type", .string, description: "New type"),
            ActionParam("description", .string, description: "New description"),
            ActionParam("attributes", .object, description: "Partial attributes (RFC 7396 merge; null deletes)"),
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
                setClauses.append("attributes = json_patch(IFNULL(attributes, '{}'), ?)")
                args.append(json)
            }

            args.append(id)
            let sql = "UPDATE entities SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

            do {
                try ctx.dbPool.write { db in
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
                        // Same shared rule as every other name-keyed door — a
                        // reference bump landing on the empty fork instead of
                        // the hub is a reference lost.
                        guard let row = try resolveEntityByName(db, name: name) else { return nil }
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
