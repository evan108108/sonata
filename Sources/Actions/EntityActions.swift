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
/// caller resolved unambiguously but should still know about. `action` splits
/// the `created: false` case: an upsert that rewrote a row with the values it
/// already held is `unchanged`, so a caller re-running a batch can tell "I
/// changed N rows" from "N rows were already right".
struct EntityUpsertResponse: Encodable {
    let id: String
    let success = true
    let created: Bool
    /// `id` | `name+type` | `created`
    let matchedBy: String
    /// `inserted` | `updated` | `unchanged`
    let action: String
    let warnings: [String]?
}

/// Whether an upsert's UPDATE would change the stored row. `name` is nil for
/// the name-matched path, which never rewrites the stored spelling. A nil
/// `attributesJSON` keeps the stored attributes (the UPDATE COALESCEs it), so
/// it is never a change. Attributes compare as parsed JSON, not as strings,
/// because dictionary key order is not stable across encodes.
private func entityUpsertWouldChange(
    _ db: Database, id: String, name: String?, type: String, description: String, attributesJSON: String?
) throws -> Bool {
    guard let row = try Row.fetchOne(
        db,
        sql: "SELECT name, type, description, attributes FROM entities WHERE id = ?",
        arguments: [id]
    ) else { return true }
    if let name, name != (row["name"] as String) { return true }
    if type != (row["type"] as String) { return true }
    if description != (row["description"] as String) { return true }
    guard let attributesJSON else { return false }
    guard let stored: String = row["attributes"] else { return true }
    guard let new = try? JSONSerialization.jsonObject(with: Data(attributesJSON.utf8)) as? NSObject,
          let old = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? NSObject else {
        return attributesJSON != stored
    }
    return !new.isEqual(old)
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

            Names listed in a row's `attributes.aliases` resolve to that row everywhere (annotation, relations, by-name lookup). Upserting BY an alias is refused (409) so a nickname can never overwrite the canonical row's description — use the canonical name or `id`.
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
            try ToolCallMarkupGuard.check(description, field: "description")
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
                        let changed = try entityUpsertWouldChange(
                            db, id: targetId, name: name, type: type,
                            description: description, attributesJSON: attributesJSON
                        )
                        try db.execute(
                            sql: updateById,
                            arguments: [name, type, description, attributesJSON, now, targetId]
                        )
                        return EntityUpsertResponse(
                            id: targetId, created: false, matchedBy: "id",
                            action: changed ? "updated" : "unchanged", warnings: nil
                        )
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
                        return EntityUpsertResponse(id: id, created: true, matchedBy: "created", action: "inserted", warnings: nil)

                    case .matched(let target, _) where target.viaAlias:
                        // An alias is a pointer, not a license to rewrite the
                        // canonical row: upserting "Archer" must not replace
                        // Archer Frohlich's description with whatever the
                        // caller meant by the nickname.
                        throw ActionError.custom(
                            """
                            '\(name)' is an alias of \(target.label). Refusing to overwrite the canonical row \
                            through its alias. Upsert with the canonical name '\(target.name)', or pass `id` \
                            to target that row explicitly.
                            """,
                            .conflict
                        )

                    case .matched(let target, let siblings):
                        let changed = try entityUpsertWouldChange(
                            db, id: target.id, name: nil, type: type,
                            description: description, attributesJSON: attributesJSON
                        )
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
                        return EntityUpsertResponse(
                            id: target.id, created: false, matchedBy: "name+type",
                            action: changed ? "updated" : "unchanged", warnings: warnings
                        )

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
            try ToolCallMarkupGuard.check(ctx.params.string("description"), field: "description")
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
        description: """
            Delete an entity by ID. If the entity still has relations, the delete is REFUSED (409, naming the edge count) \
            so no edge is left pointing at a deleted id. To keep the edges on another row (a duplicate), use mem_entity_merge. \
            To delete the edges along with the entity (junk), pass cascade: true. Relations and entity go in one transaction.
            """,
        group: "/api/entity",
        path: "/",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Entity ID"),
            ActionParam("cascade", .boolean, description: "Also delete this entity's relations (default false: refuse if it has any)"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let cascade = ctx.params.bool("cascade") ?? false
            let outcome: EntityDeleteOutcome
            do {
                outcome = try await ctx.dbPool.write { db in try deleteEntity(db, id: id, cascade: cascade) }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            switch outcome {
            case .notFound:
                throw ActionError.notFound("entity \(id)")
            case .refused(let edges):
                throw ActionError.custom(
                    """
                    Entity \(id) still has \(edges) relation(s). Deleting it would leave them pointing at a deleted id. \
                    If it duplicates another entity, use mem_entity_merge (fromId: \(id), intoId: <canonical>) to move them first. \
                    To delete the relations with the entity, pass cascade: true.
                    """,
                    .conflict
                )
            case .deleted(let relationsDeleted):
                return EntityDeleteResponse(relationsDeleted: relationsDeleted)
            }
        }
    ),

    // POST /api/entity/merge
    SonataAction(
        name: "mem_entity_merge",
        description: """
            Merge a duplicate entity (fromId) into the canonical one (intoId), in one transaction. Every relation is \
            re-pointed to intoId. Edges intoId already has, and edges between the two rows, are dropped rather than \
            duplicated. The duplicate's name is added to intoId's attributes.aliases, and its old name, type and \
            description are kept under attributes.mergedFrom. Reference counts are summed, then fromId is deleted. \
            Pass dryRun: true to see the counts without writing.
            """,
        group: "/api/entity",
        path: "/merge",
        method: .post,
        params: [
            ActionParam("fromId", .string, required: true, description: "The duplicate entity to fold in and delete"),
            ActionParam("intoId", .string, required: true, description: "The canonical entity that keeps everything"),
            ActionParam("dryRun", .boolean, description: "Report what would change without writing (default false)"),
        ],
        handler: { ctx in
            let fromId = try ctx.params.require("fromId")
            let intoId = try ctx.params.require("intoId")
            let dryRun = ctx.params.bool("dryRun") ?? false
            do {
                let plan = try await ctx.dbPool.write { db in
                    try mergeEntity(db, fromId: fromId, intoId: intoId, dryRun: dryRun, now: nowMs())
                }
                return EntityMergeResponse(dryRun: dryRun, plan: plan)
            } catch EntityMergeError.sameEntity {
                throw ActionError.invalidParam("intoId", "must differ from fromId")
            } catch EntityMergeError.notFound(let missing) {
                throw ActionError.notFound("entity \(missing)")
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/entity/dangling-edges
    SonataAction(
        name: "mem_relation_dangling",
        description: """
            Count relations whose entity endpoint no longer exists (left behind by entity deletes before 2026-09-28), \
            with a sample. Only endpoints typed 'entity' are checked, against the entities table. Deletes them only \
            when delete: true.
            """,
        group: "/api/entity",
        path: "/dangling-edges",
        method: .post,
        params: [
            ActionParam("delete", .boolean, description: "Delete the dangling relations (default false: report only)"),
        ],
        handler: { ctx in
            let delete = ctx.params.bool("delete") ?? false
            do {
                return try await ctx.dbPool.write { db in try danglingEntityEdges(db, delete: delete) }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
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
