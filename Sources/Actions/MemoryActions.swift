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

/// Parse the inline `entities` and `relations` JSON params on `mem_store`
/// and persist them alongside the just-created memory. Best-effort — errors
/// here don't roll back the memory row; annotation is additive polish.
///
/// `entities` JSON: `[{"name": "Scout", "type": "project", "description": "..."}]`
///   Existing entities matching (name, type) are reused (dedup'd).
///
/// `relations` JSON: `[{"entity": "Scout", "relation": "about"}]`
///   `entity` matches by NAME against the just-upserted set OR pre-existing
///   entities. Skips silently if the name can't be resolved — makes calls
///   idempotent when an entity was already annotated via a prior store.
private func storeInlineEntitiesAndRelations(
    memoryId: String,
    entitiesJSON: String?,
    relationsJSON: String?,
    now: Int64,
    dbPool: DatabasePool
) async throws {
    // Parse loosely — malformed JSON just skips annotation.
    let entityDefs: [(name: String, type: String, description: String)] = {
        guard let data = entitiesJSON?.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { row in
            guard let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let type = (row["type"] as? String)?.trimmingCharacters(in: .whitespaces), !type.isEmpty
            else { return nil }
            let desc = (row["description"] as? String) ?? ""
            return (name, type, desc)
        }
    }()

    let relationDefs: [(entity: String, relation: String)] = {
        guard let data = relationsJSON?.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { row in
            guard let entity = (row["entity"] as? String)?.trimmingCharacters(in: .whitespaces), !entity.isEmpty,
                  let relation = (row["relation"] as? String)?.trimmingCharacters(in: .whitespaces), !relation.isEmpty
            else { return nil }
            return (entity, relation)
        }
    }()

    guard !entityDefs.isEmpty || !relationDefs.isEmpty else { return }

    try await dbPool.write { db in
        // (1) Upsert entities. Look up existing by (name, type) case-insensitively.
        //     entityIdByName is used by (2) below to resolve relation targets by name.
        //
        //     HAZARD — this key is STRICTER than (2)'s. A caller passing a `type` that
        //     doesn't match the stored row misses here, inserts a fork, and (because the
        //     fork lands in entityIdByName first) that fork also captures (2)'s relation,
        //     which name-only resolution would have put on the original. Create and
        //     resolve must agree on one key; today they don't. Changing which key wins is
        //     a data-model call (is identity `name`, or `name`+`type`?), not a local fix.
        var entityIdByName: [String: String] = [:]  // key = lowercased name
        for def in entityDefs {
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT id FROM entities WHERE LOWER(name) = LOWER(?) AND LOWER(type) = LOWER(?) LIMIT 1",
                arguments: [def.name, def.type]
            )
            if let existing, let id = existing["id"] as? String {
                entityIdByName[def.name.lowercased()] = id
            } else {
                let newId = newUUID()
                try db.execute(
                    sql: """
                    INSERT INTO entities
                        (id, name, type, description, attributes, referenceCount, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, NULL, 0, ?, ?)
                    """,
                    arguments: [newId, def.name, def.type, def.description, now, now]
                )
                entityIdByName[def.name.lowercased()] = newId
            }
        }

        // (2) Create relations. Resolve entity by name — first the just-upserted
        //     set, then fall back to any pre-existing entity with that name.
        for def in relationDefs {
            let key = def.entity.lowercased()
            let entityId: String
            if let id = entityIdByName[key] {
                entityId = id
            } else {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT id FROM entities WHERE LOWER(name) = LOWER(?) LIMIT 1",
                    arguments: [def.entity]
                ), let id = row["id"] as? String else {
                    continue  // No entity to link — skip this relation silently.
                }
                entityId = id
            }
            let relId = newUUID()
            try db.execute(
                sql: """
                INSERT INTO relations
                    (id, sourceId, sourceType, targetId, targetType, relation, createdAt)
                VALUES (?, ?, 'memory', ?, 'entity', ?, ?)
                """,
                arguments: [relId, memoryId, entityId, def.relation, now]
            )
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
        description: """
            Store a new memory with type, tags, source, and importance.

            For durable memories (importance ≥ 7, hard rules, feedback, decisions, learnings, references), annotate entities inline in the SAME call — one atomic operation instead of three:
              entities='[{"name":"Scout","type":"project"}]'
              relations='[{"entity":"Scout","relation":"about"}]'

            The server reuses an existing entity ONLY on an exact case-insensitive match of BOTH name and type ("Scout"/"scout" merge; "Scout Leader" does not). Any other input INSERTs a new row.

            GET THE `type` RIGHT — a wrong type silently forks the entity. Passing type "failure_mode" for an entity stored as "principle" does not update it and does not error: it creates a second empty-description row under the same name, and because relations resolve by NAME against the just-upserted set first, the new fork also STEALS the relation that belonged on the original. The call still returns success. If you are not certain of an entity's existing type, look it up (mem_entity_search) before annotating; a fork is worse than no annotation.

            Memories with entity edges get a `structural` boost in mem_recall's ranking blend, so annotated memories are discoverable via graph proximity beyond lexical match.

            Skip annotation for ephemeral content: status updates, chat snapshots, subagent-stop-hook notes with importance < 7.
            """,
        group: "/api/memory",
        path: "/",
        method: .post,
        params: [
            ActionParam("content", .string, description: "Memory content. For anything long or multi-line, prefer contentPath."),
            ActionParam("contentPath", .string, description: "Absolute path to a UTF-8 file holding the content. Use this instead of 'content' for bodies over ~1KB or containing multi-line prose. Exactly one of content/contentPath is required."),
            ActionParam("type", .string, required: true, description: "Type: learning, observation, decision, preference, error_pattern, code_pattern, conversation_summary, reflection, feeling, fact"),
            ActionParam("tags", .stringArray, description: "Tags (comma-separated or array)"),
            ActionParam("source", .string, description: "Source project/context"),
            ActionParam("importance", .number, description: "1-10 importance rating"),
            ActionParam("validFrom", .integer, description: "Validity window start (epoch ms)"),
            ActionParam("validUntil", .integer, description: "Validity window end (epoch ms)"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("topic", .string, description: "Topic namespace"),
            ActionParam("createdAt", .integer, description: "Override createdAt (epoch ms)"),
            ActionParam("l0", .string, description: "Pre-computed L0 (skips pith generation)"),
            ActionParam("l1", .string, description: "Pre-computed L1 (skips pith generation)"),
            ActionParam("entities", .string, description: """
                Optional JSON array of entities to upsert alongside this memory: `[{"name": "Scout", "type": "project", "description": "..."}]`. Existing entities matching by (name, type) are reused. Use this on durable memories (importance ≥ 7, hard rules, decisions, learnings) so future recall can surface them via graph proximity — a single mem_store call is preferable to a follow-up mem_entity_upsert.
                """),
            ActionParam("relations", .string, description: """
                Optional JSON array of relations linking this memory to entities: `[{"entity": "Scout", "relation": "about"}]`. The `entity` field is the name (matched against the just-upserted set OR existing entities). Common relation types: `about`, `mentions`, `learned_from`, `part_of`, `related_to`. Pair with `entities` on the same call for one-shot annotation.
                """),
        ],
        handler: { ctx in
            let content = try ctx.params.requireTextBody("content", pathKey: "contentPath")
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

            // Generate L0/L1 via local llama-server unless caller pre-supplied them.
            // Failure (chat server down, model missing, parse error) degrades to
            // NULL l0/l1 — the backfill task picks those up later.
            let suppliedL0 = ctx.params.string("l0")
            let suppliedL1 = ctx.params.string("l1")
            let (l0, l1): (String?, String?)
            if suppliedL0 != nil || suppliedL1 != nil {
                (l0, l1) = (suppliedL0, suppliedL1)
            } else if let pith = await Pith.generateOrNil(content: content) {
                (l0, l1) = (pith.l0, pith.l1)
            } else {
                (l0, l1) = (nil, nil)
            }

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO memories
                            (id, content, type, tags, source, importance,
                             validFrom, validUntil, project, topic,
                             l0, l1,
                             createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            id, content, type, tagsJSON,
                            source, importance,
                            validFrom, validUntil,
                            project, topic,
                            l0, l1,
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

            // Inline entity + relation annotation. Parsed from JSON strings
            // (MCP's structured-arg types can't express arrays-of-objects
            // natively). Upserts entities dedup'd by (name, type), then
            // creates memory→entity relations against the resolved ids.
            // Failures here are best-effort — the memory row is already
            // persisted, we don't want annotation errors to lose content.
            let entitiesJSON = ctx.params.string("entities")
            let relationsJSON = ctx.params.string("relations")
            if entitiesJSON != nil || relationsJSON != nil {
                try? await storeInlineEntitiesAndRelations(
                    memoryId: id, entitiesJSON: entitiesJSON,
                    relationsJSON: relationsJSON, now: now, dbPool: ctx.dbPool
                )
            }

            // Embed on insert — local model, zero marginal cost. Detached so
            // the store call doesn't wait on the embedding server; if this
            // fails (server cold/down) the EmbeddingSweeper picks the row up
            // within a minute.
            let dbPool = ctx.dbPool
            Task.detached {
                try? await embedMemoryIfMissing(dbPool: dbPool, memoryId: id, content: content)
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
            ActionParam("excludeSource", .stringArray, description: "Exclude these sources (comma-separated or array). Defaults to ['subagent-stop-hook'] unless source or includeAll is given."),
            ActionParam("excludeTags", .stringArray, description: "Exclude memories carrying any of these tags."),
            ActionParam("includeAll", .boolean, description: "Include normally-excluded noise sources (e.g. subagent-stop-hook)."),
            ActionParam("after", .string, description: "Only include memories with createdAt on/after this time. Accepts unix ms or ISO date (`2026-07-15`)."),
            ActionParam("before", .string, description: "Only include memories with createdAt on/before this time. Accepts unix ms or ISO date; bare `YYYY-MM-DD` rolls to end-of-day inclusive."),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 20
            let type = ctx.params.string("type")
            let source = ctx.params.string("source")
            let includeAll = ctx.params.bool("includeAll") ?? false
            var excludeSources = ctx.params.stringArray("excludeSource") ?? []
            let excludeTags = ctx.params.stringArray("excludeTags") ?? []
            let afterMs = parseTimeParam(ctx.params.string("after"), endOfDay: false)
            let beforeMs = parseTimeParam(ctx.params.string("before"), endOfDay: true)

            // Default: hide high-volume subagent-stop-hook noise that otherwise
            // drowns genuine recent work in mem_recent. Opt back in via includeAll,
            // an explicit source filter, or an explicit excludeSource list.
            if excludeSources.isEmpty && source == nil && !includeAll {
                excludeSources = ["subagent-stop-hook"]
            }

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
            if !excludeSources.isEmpty {
                let placeholders = excludeSources.map { _ in "?" }.joined(separator: ", ")
                // Keep NULL-source rows; NULL NOT IN (...) would otherwise drop them.
                sql += " AND (m.source IS NULL OR m.source NOT IN (\(placeholders)))"
                for s in excludeSources { args.append(s) }
            }
            if !excludeTags.isEmpty {
                let placeholders = excludeTags.map { _ in "?" }.joined(separator: ", ")
                sql += " AND NOT EXISTS (SELECT 1 FROM json_each(m.tags) je WHERE je.value IN (\(placeholders)))"
                for t in excludeTags { args.append(t) }
            }
            if let a = afterMs {
                sql += " AND m.createdAt >= ?"
                args.append(a)
            }
            if let b = beforeMs {
                sql += " AND m.createdAt <= ?"
                args.append(b)
            }
            sql += " ORDER BY m.createdAt DESC LIMIT ?"
            args.append(limit)

            do {
                let rows = try ctx.dbPool.read { db in
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
            ActionParam("after", .string, description: "Only include memories with createdAt on/after this time. Accepts unix ms or ISO date (`2026-07-15`)."),
            ActionParam("before", .string, description: "Only include memories with createdAt on/before this time. Accepts unix ms or ISO date; bare `YYYY-MM-DD` rolls to end-of-day inclusive."),
        ],
        handler: { ctx in
            let q = try ctx.params.require("q")
            let limit = ctx.params.int("limit") ?? 10
            let type = ctx.params.string("type")
            let project = ctx.params.string("project")
            let afterMs = parseTimeParam(ctx.params.string("after"), endOfDay: false)
            let beforeMs = parseTimeParam(ctx.params.string("before"), endOfDay: true)

            let ftsQuery = ftsEscape(q)
            guard !ftsQuery.isEmpty else { return [MemoryResponse]() }

            var sql = """
                SELECT m.* FROM memories m
                JOIN memories_fts fts ON fts.rowid = m.rowid
                WHERE memories_fts MATCH ?
            """
            var args: [any DatabaseValueConvertible] = [ftsQuery]

            if let t = type {
                sql += " AND m.type = ?"
                args.append(t)
            }
            if let p = project {
                sql += " AND m.project = ?"
                args.append(p)
            }
            if let a = afterMs {
                sql += " AND m.createdAt >= ?"
                args.append(a)
            }
            if let b = beforeMs {
                sql += " AND m.createdAt <= ?"
                args.append(b)
            }
            sql += " ORDER BY m.createdAt DESC LIMIT ?"
            args.append(limit)

            do {
                let rows = try ctx.dbPool.read { db in
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

            let newContent = ctx.params.string("content")
            let suppliedL0 = ctx.params.string("l0")
            let suppliedL1 = ctx.params.string("l1")

            if let v = newContent                        { setClauses.append("content = ?");      args.append(v) }
            if let v = ctx.params.string("type")         { setClauses.append("type = ?");         args.append(v) }
            if let v = ctx.params.stringArray("tags")    { setClauses.append("tags = ?");         args.append(encodeTags(v)) }
            if let v = ctx.params.string("source")       { setClauses.append("source = ?");       args.append(v) }
            if let v = ctx.params.double("importance")   { setClauses.append("importance = ?");   args.append(v) }
            if let v = suppliedL0                        { setClauses.append("l0 = ?");           args.append(v) }
            if let v = suppliedL1                        { setClauses.append("l1 = ?");           args.append(v) }

            // Content changed and caller didn't override l0/l1 → regenerate them
            // from the new content. Old tiers describe stale text otherwise.
            // Fail-soft: leave l0/l1 untouched on pith error (the backfill task
            // will catch the inconsistency and refresh).
            if let updatedContent = newContent, suppliedL0 == nil, suppliedL1 == nil,
               let pith = await Pith.generateOrNil(content: updatedContent) {
                setClauses.append("l0 = ?")
                args.append(pith.l0)
                setClauses.append("l1 = ?")
                args.append(pith.l1)
            }
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
            // Build the arguments before the closure rather than inside it.
            // `[any DatabaseValueConvertible]` is not Sendable, so capturing
            // `args` in the @Sendable write closure is an error under the Swift 6
            // language mode. StatementArguments *is* Sendable (GRDB, Statement.swift),
            // so converting out here keeps the capture legal instead of merely
            // snapshotting a still-non-Sendable array.
            // Mapping through `databaseValue` also picks the non-failable
            // Sequence initializer — `StatementArguments([Any])` is failable and
            // would force an unwrap here for no benefit.
            let finalArgs = StatementArguments(args.map(\.databaseValue))

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: sql, arguments: finalArgs)
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
            ActionParam("originalId", .string, description: "Existing memory ID (alias: id). Required."),
            ActionParam("id", .string, description: "Alias for originalId."),
            ActionParam("content", .string, description: "New content. For anything long or multi-line, prefer contentPath."),
            ActionParam("contentPath", .string, description: "Absolute path to a UTF-8 file holding the new content. Exactly one of content/contentPath is required."),
            ActionParam("type", .string, description: "New type (defaults to original)"),
            ActionParam("tags", .stringArray, description: "New tags (defaults to original)"),
            ActionParam("source", .string, description: "New source"),
            ActionParam("importance", .number, description: "New importance"),
            ActionParam("revisionNote", .string, description: "Why this revision was made"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("topic", .string, description: "Topic namespace"),
        ],
        handler: { ctx in
            let originalId = try ctx.params.requireAny(["originalId", "id"])
            let content = try ctx.params.requireTextBody("content", pathKey: "contentPath")

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

            // The revised memory has new content, so regenerate L0/L1 from that
            // content (don't carry over the original's tiers — they describe the
            // old text). Fail-soft: NULL l0/l1 on pith error.
            let pith = await Pith.generateOrNil(content: content)
            let l0 = pith?.l0
            let l1 = pith?.l1

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO memories
                            (id, content, type, tags, source, importance,
                             revisionOf, revisionNote, project, topic,
                             l0, l1,
                             validFrom, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            newId, content, newType, tagsJSON,
                            source, importance,
                            originalId, revisionNote,
                            project, topic,
                            l0, l1,
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
            let row: MemoryRow?
            do {
                // Fetch the memory before archiving so we can write it to disk
                row = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            // An UPDATE matching no rows is not a success. Reporting one lets a
            // typo'd id read as "archived" forever.
            guard var archivedRow = row else {
                throw ActionError.notFound("Memory '\(id)' not found")
            }
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE memories SET status = 'archived', updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            archivedRow.status = "archived"
            writeMemoryToArchive(archivedRow)
            if let meili = ctx.search { await meili.indexArchivedMemory(archivedRow) }
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
                let exists = try await ctx.dbPool.read { db in
                    try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM memories WHERE id = ?)",
                        arguments: [id]
                    ) ?? false
                }
                guard exists else {
                    throw ActionError.notFound("Memory '\(id)' not found")
                }
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE memories SET status = 'active', updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                }
            } catch let error as ActionError {
                throw error
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),
]
