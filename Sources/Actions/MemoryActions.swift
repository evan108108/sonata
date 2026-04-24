import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/memory routes.
// Handler logic is duplicated from MemoryRoutes.swift so the two implementations
// run side-by-side. When the old routes are retired these become canonical.

// Write a memory to ~/.sonata/archive/ as a markdown file for Spotlight indexing.
// Called when memories are archived or superseded so the full text remains searchable
// via mdfind even after the memory leaves active recall.
private func writeMemoryToArchive(_ row: MemoryRow) {
    let fm = FileManager.default
    let archiveDir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("memory/archive")
    try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

    // Format date from createdAt (ms epoch)
    let date = Date(timeIntervalSince1970: Double(row.createdAt) / 1000.0)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    let dateStr = fmt.string(from: date)

    let shortId = String(row.id.prefix(8))
    let filename = "\(dateStr)_\(shortId).md"
    let filePath = archiveDir.appendingPathComponent(filename)

    // Build frontmatter
    var lines: [String] = ["---"]
    lines.append("id: \(row.id)")
    lines.append("type: \(row.type)")
    if let source = row.source { lines.append("source: \(source)") }
    lines.append("importance: \(Int(row.importance))")
    if let project = row.project { lines.append("project: \(project)") }
    if let topic = row.topic { lines.append("topic: \(topic)") }
    lines.append("tags: \(row.tagsJSON)")
    lines.append("created: \(dateStr)")
    if let status = row.status { lines.append("status: \(status)") }
    if let supersededBy = row.supersededBy { lines.append("superseded_by: \(supersededBy)") }
    if let revisionOf = row.revisionOf { lines.append("revision_of: \(revisionOf)") }
    lines.append("---")
    lines.append("")
    lines.append(row.content)
    lines.append("")

    let content = lines.joined(separator: "\n")
    try? content.write(to: filePath, atomically: true, encoding: .utf8)
}

private let validMemoryTypesForActions: Set<String> = [
    "learning", "observation", "decision", "preference",
    "error_pattern", "code_pattern", "conversation_summary",
    "reflection", "feeling", "fact"
]

// Common learning-tag → wiki-slug mapping. Tags written on learning memories
// frequently describe implementation surface (swift, macos, subprocess) rather
// than a wiki topic name, so we route them to the right page(s) explicitly.
private let learningTagSlugMap: [String: [String]] = [
    "swift": ["sonata"],
    "macos": ["sonata"],
    "app-bundle": ["sonata"],
    "process": ["sonata"],
    "subprocess": ["sonata"],
    "launchd": ["sonata"],
    "grdb": ["sonata/database"],
    "sqlite": ["sonata/database"],
    "hummingbird": ["sonata/http-api"],
    "meilisearch": ["sonata/learnings", "sonata"],
    "search": ["sonata/learnings", "sonata"],
    "recall": ["sonata/recall", "memory-system/recall"],
    "wiki": ["memory-system/wiki"],
    "scheduler": ["sonata/scheduler"],
    "worker": ["sonata/workers"],
    "sonaworker": ["sonata/workers"],
    "backup": ["sonata/backup"],
    "dashboard": ["sonata/dashboard"],
    "scout": ["scout-pipeline"],
    "evenflow": ["evenflow"],
    "agentmail": ["agentmail"],
    "prstar": ["prstar"],
]

// Flag wiki pages dirty based on a just-stored memory's namespace and tags.
// Mirrors the Convex flagDirtyFromMemory logic with an extra tag→slug map
// for learning memories. Silently no-ops on any DB error so we never break a
// successful memory store.
private func flagDirtyFromMemory(
    db: Database,
    type: String,
    source: String?,
    project: String?,
    topic: String?,
    tags: [String]
) {
    let now = nowMs()
    var flagged = Set<String>()

    func markDirty(slug: String) {
        if flagged.contains(slug) { return }
        flagged.insert(slug)
        try? db.execute(
            sql: "UPDATE wikiPages SET dirty = 1, updatedAt = ? WHERE slug = ? AND dirty = 0",
            arguments: [now, slug]
        )
    }

    func markDirtyByNamespace(_ ns: String) {
        if let slug = try? String.fetchOne(db,
            sql: "SELECT slug FROM wikiPages WHERE namespace = ? LIMIT 1",
            arguments: [ns]) {
            markDirty(slug: slug)
        }
    }

    // Strategy 1: namespace from project or source
    if let namespace = (project ?? source)?.lowercased(), !namespace.isEmpty {
        markDirtyByNamespace(namespace)

        // Topic page within that namespace
        if let topicLower = topic?.lowercased(), !topicLower.isEmpty {
            if let slug = try? String.fetchOne(db,
                sql: "SELECT slug FROM wikiPages WHERE namespace = ? AND topic = ? LIMIT 1",
                arguments: [namespace, topicLower]) {
                markDirty(slug: slug)
            }
        }
    }

    // Strategy 2: match tags against wiki page topics in common knowledge
    // namespaces. Keeps existing non-learning behavior intact.
    let topicNamespaces = ["memory-system", "memory", "sonata", "sona"]
    for tag in tags.prefix(5) {
        let tagLower = tag.lowercased()
        for ns in topicNamespaces {
            if let slugs = try? String.fetchAll(db,
                sql: "SELECT slug FROM wikiPages WHERE namespace = ? AND topic = ?",
                arguments: [ns, tagLower]) {
                for slug in slugs { markDirty(slug: slug) }
            }
        }
    }

    // Strategy 3: learning-only tag→slug map. Learnings tend to tag by
    // implementation surface, which rarely matches a wiki topic directly.
    if type == "learning" {
        for tag in tags {
            guard let slugs = learningTagSlugMap[tag.lowercased()] else { continue }
            for slug in slugs { markDirty(slug: slug) }
        }
    }
}

func memRowToResponse(_ row: MemoryRow) -> MemoryResponse {
    MemoryResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        content: row.content,
        type: row.type,
        tags: parseTags(row.tagsJSON),
        source: row.source,
        importance: row.importance,
        l0: row.l0,
        l1: row.l1,
        accessCount: row.accessCount,
        lastAccessedAt: row.lastAccessedAt,
        status: row.status,
        supersededBy: row.supersededBy,
        revisionOf: row.revisionOf,
        revisionNote: row.revisionNote,
        validFrom: row.validFrom,
        validUntil: row.validUntil,
        project: row.project,
        topic: row.topic,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

let memoryActions: [SonataAction] = [

    // GET / — health check
    SonataAction(
        name: "health",
        description: "Service health check.",
        group: "",
        path: "/",
        method: .get,
        params: [],
        httpOnly: true,
        handler: { _ in
            HealthResponse()
        }
    ),

    // POST /api/memory — store a new memory
    SonataAction(
        name: "mem_store",
        description: "Store a new memory with type, tags, source, and importance.",
        group: "/api/memory",
        path: "/",
        method: .post,
        params: [
            ActionParam("content", .string, required: true, description: "Memory content"),
            ActionParam("type", .string, required: true, description: "Type: learning, observation, decision, preference, error_pattern, code_pattern, conversation_summary, reflection, feeling, fact"),
            ActionParam("tags", .stringArray, description: "Tags (comma-separated or array)"),
            ActionParam("source", .string, description: "Source project/context"),
            ActionParam("importance", .number, description: "1-10 importance rating"),
            ActionParam("validFrom", .integer, description: "Validity window start (epoch ms)"),
            ActionParam("validUntil", .integer, description: "Validity window end (epoch ms)"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("topic", .string, description: "Topic namespace"),
            ActionParam("createdAt", .integer, description: "Override createdAt (epoch ms)"),
        ],
        handler: { ctx in
            let content = try ctx.params.require("content")
            let type = try ctx.params.require("type")
            guard validMemoryTypesForActions.contains(type) else {
                throw ActionError.invalidParam("type", "Invalid memory type '\(type)'")
            }

            let now = nowMs()
            let createdAt = ctx.params.int("createdAt").map { Int64($0) } ?? now
            let id = newUUID()
            let tags = ctx.params.stringArray("tags") ?? []
            let tagsJSON = encodeTags(tags)
            let source = ctx.params.string("source")
            let importance = ctx.params.double("importance") ?? 5.0
            let validFrom = ctx.params.int("validFrom").map { Int64($0) } ?? createdAt
            let validUntil = ctx.params.int("validUntil").map { Int64($0) }
            let project = ctx.params.string("project")
            let topic = ctx.params.string("topic")

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO memories
                            (id, content, type, tags, source, importance,
                             validFrom, validUntil, project, topic,
                             createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            id, content, type, tagsJSON,
                            source, importance,
                            validFrom, validUntil,
                            project, topic,
                            createdAt, createdAt
                        ]
                    )
                    flagDirtyFromMemory(
                        db: db,
                        type: type,
                        source: source,
                        project: project,
                        topic: topic,
                        tags: tags
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            return StoreResponse(id: id)
        }
    ),

    // GET /api/memory/recent
    SonataAction(
        name: "mem_recent",
        description: "List recent memories ordered by createdAt DESC.",
        group: "/api/memory",
        path: "/recent",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 20)"),
            ActionParam("type", .string, description: "Filter by memory type"),
            ActionParam("source", .string, description: "Filter by source"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 20
            let type = ctx.params.string("type")
            let source = ctx.params.string("source")

            var sql = "SELECT * FROM memories m WHERE 1=1"
            var args: [any DatabaseValueConvertible] = []

            if let t = type {
                sql += " AND m.type = ?"
                args.append(t)
            }
            if let s = source {
                sql += " AND m.source = ?"
                args.append(s)
            }
            sql += " ORDER BY m.createdAt DESC LIMIT ?"
            args.append(limit)

            do {
                let rows = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(memRowToResponse)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/memory/search
    SonataAction(
        name: "mem_search",
        description: "Full-text search on memories (FTS5).",
        group: "/api/memory",
        path: "/search",
        method: .get,
        params: [
            ActionParam("q", .string, required: true, description: "FTS5 query string"),
            ActionParam("limit", .integer, description: "Max results (default 10)"),
            ActionParam("type", .string, description: "Filter by memory type"),
            ActionParam("project", .string, description: "Filter by project"),
        ],
        handler: { ctx in
            let q = try ctx.params.require("q")
            let limit = ctx.params.int("limit") ?? 10
            let type = ctx.params.string("type")
            let project = ctx.params.string("project")

            var sql = """
                SELECT m.* FROM memories m
                JOIN memories_fts fts ON fts.rowid = m.rowid
                WHERE memories_fts MATCH ?
            """
            var args: [any DatabaseValueConvertible] = [q]

            if let t = type {
                sql += " AND m.type = ?"
                args.append(t)
            }
            if let p = project {
                sql += " AND m.project = ?"
                args.append(p)
            }
            sql += " ORDER BY m.createdAt DESC LIMIT ?"
            args.append(limit)

            do {
                let rows = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(memRowToResponse)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/memory/touch
    SonataAction(
        name: "mem_touch",
        description: "Increment accessCount and set lastAccessedAt for a batch of memory IDs.",
        group: "/api/memory",
        path: "/touch",
        method: .post,
        params: [
            ActionParam("ids", .stringArray, required: true, description: "Memory IDs"),
        ],
        handler: { ctx in
            let ids = ctx.params.stringArray("ids") ?? []
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    for id in ids {
                        try db.execute(
                            sql: """
                            UPDATE memories
                            SET accessCount = COALESCE(accessCount, 0) + 1,
                                lastAccessedAt = ?
                            WHERE id = ?
                            """,
                            arguments: [now, id]
                        )
                    }
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            return TouchResponse(touched: ids.count)
        }
    ),

    // GET /api/memory/get?id=
    SonataAction(
        name: "mem_expand",
        description: "Get a memory by id (query-param style).",
        group: "/api/memory",
        path: "/get",
        method: .get,
        params: [
            ActionParam("id", .string, required: true, description: "Memory ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                let row = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                }
                guard let row else {
                    throw ActionError.notFound("Memory not found")
                }
                return memRowToResponse(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/memory/:id
    SonataAction(
        name: "mem_get_by_id",
        description: "Get a memory by id (path-param style).",
        group: "/api/memory",
        path: "/:id",
        method: .get,
        params: [
            ActionParam("id", .string, required: true, description: "Memory ID", source: .path),
        ],
        httpOnly: true,
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                let row = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                }
                guard let row else {
                    throw ActionError.notFound("Memory not found")
                }
                return memRowToResponse(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // PATCH /api/memory
    SonataAction(
        name: "mem_patch",
        description: "Partial update of a memory by id.",
        group: "/api/memory",
        path: "/",
        method: .patch,
        params: [
            ActionParam("id", .string, required: true, description: "Memory ID"),
            ActionParam("content", .string, description: "New content"),
            ActionParam("type", .string, description: "New type"),
            ActionParam("tags", .stringArray, description: "New tags"),
            ActionParam("source", .string, description: "New source"),
            ActionParam("importance", .number, description: "New importance"),
            ActionParam("l0", .string, description: "New l0 summary"),
            ActionParam("l1", .string, description: "New l1 summary"),
            ActionParam("status", .string, description: "New status"),
            ActionParam("supersededBy", .string, description: "Superseded-by memory id"),
            ActionParam("revisionOf", .string, description: "Revision-of memory id"),
            ActionParam("revisionNote", .string, description: "Revision note"),
            ActionParam("validFrom", .integer, description: "Validity window start"),
            ActionParam("validUntil", .integer, description: "Validity window end"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("topic", .string, description: "Topic namespace"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            if let t = ctx.params.string("type"), !validMemoryTypesForActions.contains(t) {
                throw ActionError.invalidParam("type", "Invalid memory type '\(t)'")
            }

            let now = nowMs()
            var setClauses: [String] = ["updatedAt = ?"]
            var args: [any DatabaseValueConvertible] = [now]

            if let v = ctx.params.string("content")      { setClauses.append("content = ?");      args.append(v) }
            if let v = ctx.params.string("type")         { setClauses.append("type = ?");         args.append(v) }
            if let v = ctx.params.stringArray("tags")    { setClauses.append("tags = ?");         args.append(encodeTags(v)) }
            if let v = ctx.params.string("source")       { setClauses.append("source = ?");       args.append(v) }
            if let v = ctx.params.double("importance")   { setClauses.append("importance = ?");   args.append(v) }
            if let v = ctx.params.string("l0")           { setClauses.append("l0 = ?");           args.append(v) }
            if let v = ctx.params.string("l1")           { setClauses.append("l1 = ?");           args.append(v) }
            if let v = ctx.params.string("status")       { setClauses.append("status = ?");       args.append(v) }
            if let v = ctx.params.string("supersededBy") { setClauses.append("supersededBy = ?"); args.append(v) }
            if let v = ctx.params.string("revisionOf")   { setClauses.append("revisionOf = ?");   args.append(v) }
            if let v = ctx.params.string("revisionNote") { setClauses.append("revisionNote = ?"); args.append(v) }
            if let v = ctx.params.int("validFrom")       { setClauses.append("validFrom = ?");    args.append(Int64(v)) }
            if let v = ctx.params.int("validUntil")      { setClauses.append("validUntil = ?");   args.append(Int64(v)) }
            if let v = ctx.params.string("project")      { setClauses.append("project = ?");      args.append(v) }
            if let v = ctx.params.string("topic")        { setClauses.append("topic = ?");        args.append(v) }

            args.append(id)
            let sql = "UPDATE memories SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

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

    // DELETE /api/memory?id=
    SonataAction(
        name: "mem_delete",
        description: "Delete a memory by id (query-param style).",
        group: "/api/memory",
        path: "/",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Memory ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // DELETE /api/memory/:id
    SonataAction(
        name: "mem_delete_by_id",
        description: "Delete a memory by id (path-param style).",
        group: "/api/memory",
        path: "/:id",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Memory ID", source: .path),
        ],
        httpOnly: true,
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/memory/revise
    SonataAction(
        name: "mem_revise",
        description: "Create a new memory that supersedes an existing one.",
        group: "/api/memory",
        path: "/revise",
        method: .post,
        params: [
            ActionParam("originalId", .string, required: true, description: "Existing memory ID"),
            ActionParam("content", .string, required: true, description: "New content"),
            ActionParam("type", .string, description: "New type (defaults to original)"),
            ActionParam("tags", .stringArray, description: "New tags (defaults to original)"),
            ActionParam("source", .string, description: "New source"),
            ActionParam("importance", .number, description: "New importance"),
            ActionParam("revisionNote", .string, description: "Why this revision was made"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("topic", .string, description: "Topic namespace"),
        ],
        handler: { ctx in
            let originalId = try ctx.params.require("originalId")
            let content = try ctx.params.require("content")

            let original: MemoryRow?
            do {
                original = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [originalId])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            guard let orig = original else {
                throw ActionError.notFound("Original memory not found")
            }

            let now = nowMs()
            let newId = newUUID()
            let newType = ctx.params.string("type") ?? orig.type
            guard validMemoryTypesForActions.contains(newType) else {
                throw ActionError.invalidParam("type", "Invalid memory type '\(newType)'")
            }
            let tagsJSON = ctx.params.stringArray("tags").map(encodeTags) ?? orig.tagsJSON
            let source = ctx.params.string("source") ?? orig.source
            let importance = ctx.params.double("importance") ?? orig.importance
            let revisionNote = ctx.params.string("revisionNote")
            let project = ctx.params.string("project") ?? orig.project
            let topic = ctx.params.string("topic") ?? orig.topic

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO memories
                            (id, content, type, tags, source, importance,
                             revisionOf, revisionNote, project, topic,
                             validFrom, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            newId, content, newType, tagsJSON,
                            source, importance,
                            originalId, revisionNote,
                            project, topic,
                            now, now, now
                        ]
                    )
                    try db.execute(
                        sql: """
                        UPDATE memories
                        SET supersededBy = ?, status = 'superseded', updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [newId, now, originalId]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            // Write the original to disk before it disappears from recall
            var archivedOrig = orig
            archivedOrig.status = "superseded"
            archivedOrig.supersededBy = newId
            writeMemoryToArchive(archivedOrig)
            if let meili = ctx.search { await meili.indexArchivedMemory(archivedOrig) }

            return StoreResponse(id: newId)
        }
    ),

    // POST /api/memory/supersede
    SonataAction(
        name: "mem_supersede",
        description: "Mark an older memory as superseded by a newer one.",
        group: "/api/memory",
        path: "/supersede",
        method: .post,
        params: [
            ActionParam("oldId", .string, required: true, description: "Memory to mark superseded"),
            ActionParam("newId", .string, required: true, description: "Superseding memory ID"),
        ],
        handler: { ctx in
            let oldId = try ctx.params.require("oldId")
            let newId = try ctx.params.require("newId")

            let now = nowMs()
            do {
                // Fetch the memory before superseding so we can write it to disk
                let row = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [oldId])
                }
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        UPDATE memories
                        SET supersededBy = ?, status = 'superseded', updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [newId, now, oldId]
                    )
                    try db.execute(
                        sql: """
                        UPDATE memories
                        SET revisionOf = ?, updatedAt = ?
                        WHERE id = ? AND revisionOf IS NULL
                        """,
                        arguments: [oldId, now, newId]
                    )
                }
                if var supersededRow = row {
                    supersededRow.status = "superseded"
                    supersededRow.supersededBy = newId
                    writeMemoryToArchive(supersededRow)
                    if let meili = ctx.search { await meili.indexArchivedMemory(supersededRow) }
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/memory/archive?id=
    SonataAction(
        name: "mem_archive",
        description: "Archive a memory (status='archived').",
        group: "/api/memory",
        path: "/archive",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Memory ID", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                // Fetch the memory before archiving so we can write it to disk
                let row = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                }
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE memories SET status = 'archived', updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                }
                if var archivedRow = row {
                    archivedRow.status = "archived"
                    writeMemoryToArchive(archivedRow)
                    if let meili = ctx.search { await meili.indexArchivedMemory(archivedRow) }
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/memory/unarchive?id=
    SonataAction(
        name: "mem_unarchive",
        description: "Unarchive a memory (status='active').",
        group: "/api/memory",
        path: "/unarchive",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Memory ID", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE memories SET status = 'active', updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),
]
