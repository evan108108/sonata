import Foundation
import GRDB
import Hummingbird
#if canImport(Accelerate)
import Accelerate
#endif

// Phase 2 migration: action definition for GET /api/recall.
// Handler logic is duplicated from RecallRoutes.swift along with every private
// helper and response-type struct it depends on. Private members coexist with
// the originals because Swift's `private` scopes to a single file.

// MARK: - Token estimation

private func recallEstimateTokens(_ text: String) -> Int {
    (text.count + 3) / 4
}

// MARK: - Scoring

private func recallScoreMemory(_ mem: MemoryRow, searchRank: Int, now: Int64, vectorScore: Double? = nil) -> Double {
    let importance = mem.importance
    let ageHours = Double(now - mem.createdAt) / (1000 * 60 * 60)
    let recencyScore = max(0.0, 1.0 - ageHours / (24 * 30))
    let accessScore = min(1.0, Double(mem.accessCount ?? 0) / 20.0)
    let searchRelevance = max(0.0, 1.0 - Double(searchRank) / 30.0)

    if let vs = vectorScore {
        return searchRelevance * 0.25
            + vs * 0.25
            + (importance / 10.0) * 0.20
            + recencyScore * 0.15
            + accessScore * 0.05
    } else {
        return searchRelevance * 0.40
            + (importance / 10.0) * 0.20
            + recencyScore * 0.15
            + accessScore * 0.05
    }
}

// MARK: - Response Types

private struct RecallMemoryAction: Encodable {
    let _id: String
    let _creationTime: Int64
    let content: String?
    let type: String
    let tags: [String]
    let source: String?
    let importance: Double
    let l0: String?
    let l1: String?
    let accessCount: Int?
    let lastAccessedAt: Int64?
    let status: String?
    let supersededBy: String?
    let revisionOf: String?
    let revisionNote: String?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
    let createdAt: Int64
    let updatedAt: Int64
    let _searchRank: Int
    let _rankScore: Double
    let _tier: String

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encode(type, forKey: .type)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(importance, forKey: .importance)
        try c.encodeIfPresent(l0, forKey: .l0)
        try c.encodeIfPresent(l1, forKey: .l1)
        try c.encodeIfPresent(accessCount, forKey: .accessCount)
        try c.encodeIfPresent(lastAccessedAt, forKey: .lastAccessedAt)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(supersededBy, forKey: .supersededBy)
        try c.encodeIfPresent(revisionOf, forKey: .revisionOf)
        try c.encodeIfPresent(revisionNote, forKey: .revisionNote)
        try c.encodeIfPresent(validFrom, forKey: .validFrom)
        try c.encodeIfPresent(validUntil, forKey: .validUntil)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(topic, forKey: .topic)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(_searchRank, forKey: ._searchRank)
        try c.encode(_rankScore, forKey: ._rankScore)
        try c.encode(_tier, forKey: ._tier)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case content, type, tags, source, importance
        case l0, l1
        case accessCount, lastAccessedAt
        case status, supersededBy, revisionOf, revisionNote
        case validFrom, validUntil, project, topic
        case createdAt, updatedAt
        case _searchRank, _rankScore, _tier
    }
}

private struct DocumentSummaryAction: Encodable {
    let _id: String
    let title: String
    let path: String
    let docType: String
    let project: String?
    let status: String
    let tags: [String]
    let summary: String?
    let updatedAt: Int64
}

private struct WikiPageResultAction: Encodable {
    let slug: String
    let title: String
    let snippet: String
    let path: String
}

private struct WanderMemoryAction: Encodable {
    let _id: String
    let type: String
    let l0: String?
    let content: String?
    let importance: Double
    let createdAt: Int64
    let _adjacency: String
    let _anchorId: String?
    let _anchorSummary: String?
    let _gapMinutes: Int?
    let _viaEntity: String?
    let _relation: String?
    let _score: Double?
}

private struct TokenUsageAction: Encodable {
    let budget: Int
    let used: Int
    let memoriesIncluded: Int
    let memoriesTotal: Int
    let truncated: Bool
    let tier: String
    let unreturnedCandidates: Int
}

private struct DocSearchResultResponse: Encodable {
    let id: String
    let title: String
    let snippet: String
    let index: String
}

private struct RecallResponseAction: Encodable {
    let memories: [RecallMemoryAction]
    let entities: [EntityResponse]
    let relations: [RelationResponse]
    let documents: [DocumentSummaryAction]
    let wikiPages: [WikiPageResultAction]
    let wander: [WanderMemoryAction]
    let wanderCount: Int
    let query: String
    let vectorResultCount: Int
    let partial: Bool
    let tokenUsage: TokenUsageAction
    let _timings: [String: Int]
}

private struct FetchFullResponse: Encodable {
    let memories: [RecallMemoryAction]
    let requested: Int
    let found: Int
}

// MARK: - Internal scored memory container

private struct ScoredMemoryAction {
    let row: MemoryRow
    let searchRank: Int
    let rankScore: Double
}

private struct Phase1ResultAction {
    let memories: [MemoryRow]
    let entitySearch: [EntityRow]
    let exactEntity: EntityRow?
    let exactEntities: [EntityRow]
    let documents: [DocumentRow]
}

// MARK: - FTS helpers (duplicated from RecallRoutes.swift)

private func recallFtsSearchMemories(
    db: Database, query: String, limit: Int,
    project: String?, filterTopic: String?
) throws -> [MemoryRow] {
    let ftsQuery = ftsEscape(query)
    guard !ftsQuery.isEmpty else { return [] }

    var sql = """
        SELECT m.* FROM memories m
        JOIN memories_fts fts ON fts.rowid = m.rowid
        WHERE memories_fts MATCH ?
    """
    var args: [any DatabaseValueConvertible] = [ftsQuery]

    if let p = project {
        sql += " AND m.project = ?"
        args.append(p)
    }
    if let t = filterTopic {
        sql += " AND m.topic = ?"
        args.append(t)
    }

    sql += " AND (m.status IS NULL OR m.status = 'active')"
    sql += " ORDER BY rank LIMIT ?"
    args.append(limit)

    return try MemoryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
}

private func recallFtsSearchEntities(db: Database, query: String, limit: Int) throws -> [EntityRow] {
    let ftsQuery = ftsEscapeOR(query)
    guard !ftsQuery.isEmpty else { return [] }

    return try EntityRow.fetchAll(
        db,
        sql: """
            SELECT e.* FROM entities e
            JOIN entities_fts fts ON fts.rowid = e.rowid
            WHERE entities_fts MATCH ?
            ORDER BY rank LIMIT ?
        """,
        arguments: [ftsQuery, limit]
    )
}

private func recallFtsSearchDocuments(db: Database, query: String, limit: Int) throws -> [DocumentRow] {
    let ftsQuery = ftsEscape(query)
    guard !ftsQuery.isEmpty else { return [] }

    return try DocumentRow.fetchAll(
        db,
        sql: """
            SELECT d.* FROM documents d
            JOIN documents_fts fts ON fts.rowid = d.rowid
            WHERE documents_fts MATCH ?
            AND (d.status = 'active' OR d.status = 'draft')
            ORDER BY rank LIMIT ?
        """,
        arguments: [ftsQuery, limit]
    )
}

private func recallFetchRelations(db: Database, id: String, type: String) throws -> [RelationRow] {
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

private func recallMsElapsed(since start: DispatchTime) -> Int {
    let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return Int(ns / 1_000_000)
}

private func recallEncodeMemoryForBudget(_ mem: MemoryRow, tags: [String]) -> String {
    let tagsStr = tags.joined(separator: "\",\"")
    return """
    {"_id":"\(mem.id)","type":"\(mem.type)","content":"\(mem.content)","importance":\(mem.importance),"tags":["\(tagsStr)"],"source":"\(mem.source ?? "")","l0":"\(mem.l0 ?? "")","l1":"\(mem.l1 ?? "")","createdAt":\(mem.createdAt),"updatedAt":\(mem.updatedAt)}
    """
}

private func recallMakeRecallMemory(
    _ mem: MemoryRow,
    tags: [String],
    searchRank: Int,
    rankScore: Double,
    tier: String,
    includeContent: Bool,
    overrideL0: String? = nil,
    overrideL1: String? = nil
) -> RecallMemoryAction {
    RecallMemoryAction(
        _id: mem.id,
        _creationTime: mem.createdAt,
        content: includeContent ? mem.content : nil,
        type: mem.type,
        tags: tags,
        source: (tier == "full" || tier == "l1") ? mem.source : nil,
        importance: mem.importance,
        l0: overrideL0 ?? mem.l0,
        l1: (tier == "full" || tier == "l1") ? (overrideL1 ?? mem.l1) : nil,
        accessCount: includeContent ? mem.accessCount : nil,
        lastAccessedAt: includeContent ? mem.lastAccessedAt : nil,
        status: includeContent ? mem.status : nil,
        supersededBy: includeContent ? mem.supersededBy : nil,
        revisionOf: includeContent ? mem.revisionOf : nil,
        revisionNote: includeContent ? mem.revisionNote : nil,
        validFrom: includeContent ? mem.validFrom : nil,
        validUntil: includeContent ? mem.validUntil : nil,
        project: includeContent ? mem.project : nil,
        topic: includeContent ? mem.topic : nil,
        createdAt: mem.createdAt,
        updatedAt: mem.updatedAt,
        _searchRank: searchRank,
        _rankScore: rankScore,
        _tier: tier
    )
}

// MARK: - Wander

private func recallWanderFromAnchors(
    anchors: [MemoryRow],
    vectorScores: [String: Double],
    dbPool: DatabasePool,
    perStrategy: Int = 3
) async -> (temporal: [WanderMemoryAction], graph: [WanderMemoryAction], periphery: [WanderMemoryAction]) {
    let anchorIds = Set(anchors.map(\.id))

    // Strategy A: Temporal neighbors (±2h)
    let temporal: [WanderMemoryAction] = (try? await dbPool.read { db -> [WanderMemoryAction] in
        let windowMs: Int64 = 2 * 60 * 60 * 1000
        var seen = anchorIds
        var results: [WanderMemoryAction] = []

        for anchor in anchors.prefix(3) {
            let windowStart = anchor.createdAt - windowMs
            let windowEnd = anchor.createdAt + windowMs

            let neighbors = try MemoryRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM memories
                    WHERE createdAt BETWEEN ? AND ?
                    AND (status IS NULL OR status = 'active')
                    AND id NOT IN (\(seen.map { _ in "?" }.joined(separator: ",")))
                    ORDER BY ABS(createdAt - ?) ASC
                    LIMIT ?
                """,
                arguments: StatementArguments(
                    [windowStart, windowEnd]
                    + Array(seen)
                    + [anchor.createdAt, perStrategy + 5]
                )
            )

            for n in neighbors {
                guard !seen.contains(n.id) else { continue }
                seen.insert(n.id)
                let gapMinutes = Int(abs(n.createdAt - anchor.createdAt) / 60000)
                results.append(WanderMemoryAction(
                    _id: n.id, type: n.type,
                    l0: n.l0, content: String(n.content.prefix(100)),
                    importance: n.importance, createdAt: n.createdAt,
                    _adjacency: "temporal",
                    _anchorId: anchor.id,
                    _anchorSummary: anchor.l0 ?? String(anchor.content.prefix(60)),
                    _gapMinutes: gapMinutes,
                    _viaEntity: nil, _relation: nil, _score: nil
                ))
                if results.count >= perStrategy { break }
            }
            if results.count >= perStrategy { break }
        }
        return results
    }) ?? []

    // Strategy B: Graph wander
    let graph: [WanderMemoryAction] = (try? await dbPool.read { db -> [WanderMemoryAction] in
        var seen = anchorIds
        var results: [WanderMemoryAction] = []

        for anchor in anchors.prefix(3) {
            let rels = try recallFetchRelations(db: db, id: anchor.id, type: "memory")

            var entityIds: [String] = []
            for rel in rels {
                if rel.targetType == "entity" && !entityIds.contains(rel.targetId) {
                    entityIds.append(rel.targetId)
                }
                if rel.sourceType == "entity" && !entityIds.contains(rel.sourceId) {
                    entityIds.append(rel.sourceId)
                }
            }

            for entId in entityIds.prefix(3) {
                let entRels = try recallFetchRelations(db: db, id: entId, type: "entity")

                for rel in entRels {
                    let memId = rel.targetType == "memory" ? rel.targetId
                              : rel.sourceType == "memory" ? rel.sourceId
                              : nil
                    guard let memId = memId, !seen.contains(memId) else { continue }
                    seen.insert(memId)

                    guard let mem = try MemoryRow.fetchOne(
                        db,
                        sql: "SELECT * FROM memories WHERE id = ? AND (status IS NULL OR status = 'active')",
                        arguments: [memId]
                    ) else { continue }

                    let entityName: String
                    if let ent = try EntityRow.fetchOne(
                        db,
                        sql: "SELECT * FROM entities WHERE id = ?",
                        arguments: [entId]
                    ) {
                        entityName = ent.name
                    } else {
                        entityName = entId
                    }

                    results.append(WanderMemoryAction(
                        _id: mem.id, type: mem.type,
                        l0: mem.l0, content: String(mem.content.prefix(100)),
                        importance: mem.importance, createdAt: mem.createdAt,
                        _adjacency: "graph",
                        _anchorId: anchor.id,
                        _anchorSummary: anchor.l0 ?? String(anchor.content.prefix(60)),
                        _gapMinutes: nil,
                        _viaEntity: entityName, _relation: rel.relation,
                        _score: nil
                    ))
                    if results.count >= perStrategy { break }
                }
                if results.count >= perStrategy { break }
            }
            if results.count >= perStrategy { break }
        }
        return results
    }) ?? []

    // Strategy C: Embedding periphery
    var periphery: [WanderMemoryAction] = []
    if !vectorScores.isEmpty {
        let sorted = vectorScores.sorted { $0.value > $1.value }
        let peripheryZone = Array(sorted.dropFirst(3).prefix(27))
        let shuffled = peripheryZone.shuffled()

        var peripheryIds: [(String, Double)] = []
        for (memId, score) in shuffled {
            guard !anchorIds.contains(memId) else { continue }
            peripheryIds.append((memId, score))
            if peripheryIds.count >= perStrategy { break }
        }

        if !peripheryIds.isEmpty {
            let snapshot = peripheryIds
            let fetched: [WanderMemoryAction] = (try? await dbPool.read { db -> [WanderMemoryAction] in
                var results: [WanderMemoryAction] = []
                for (memId, score) in snapshot {
                    guard let mem = try MemoryRow.fetchOne(
                        db,
                        sql: "SELECT * FROM memories WHERE id = ? AND (status IS NULL OR status = 'active')",
                        arguments: [memId]
                    ) else { continue }

                    results.append(WanderMemoryAction(
                        _id: mem.id, type: mem.type,
                        l0: mem.l0, content: String(mem.content.prefix(100)),
                        importance: mem.importance, createdAt: mem.createdAt,
                        _adjacency: "periphery",
                        _anchorId: nil, _anchorSummary: nil,
                        _gapMinutes: nil, _viaEntity: nil, _relation: nil,
                        _score: score
                    ))
                }
                return results
            }) ?? []
            periphery = fetched
        }
    }

    return (temporal: temporal, graph: graph, periphery: periphery)
}

// MARK: - MeiliSearch Wiki Search

private let recallWikiDir = NSHomeDirectory() + "/.sonata/wiki"

private func recallSearchWiki(query: String, limit: Int = 3, search: (any SearchService)?) async -> [WikiPageResultAction] {
    guard let search = search else { return [] }
    let hits = await search.searchWiki(query: query, limit: limit)

    var results: [WikiPageResultAction] = []
    for hit in hits {
        let slug = hit.id
        let title = hit.title
        let filePath = recallWikiDir + "/" + slug + ".md"
        let content = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""
        let snippet = String(content.prefix(500))
        results.append(WikiPageResultAction(slug: slug, title: title, snippet: snippet, path: filePath))
    }
    return results
}

// MARK: - Action definition

let recallActions: [SonataAction] = [

    // GET /api/recall — budget-aware multi-strategy recall
    SonataAction(
        name: "mem_recall",
        description: "Multi-strategy memory recall — text search + entity + vector + graph + wiki pages. Primary way to retrieve context about any topic.",
        group: "/api/recall",
        path: "",
        method: .get,
        params: [
            ActionParam("topic", .string, required: true, description: "What to recall"),
            ActionParam("budget", .integer, description: "Token budget for results (default 8000)"),
            ActionParam("limit", .integer, description: "Max memories to consider (default 20)"),
            ActionParam("project", .string, description: "Filter by project namespace"),
            ActionParam("filterTopic", .string, description: "Filter by topic namespace"),
            ActionParam("wander", .string, description: "'false' to disable wander (default enabled)"),
            ActionParam("tier", .string, description: "Response tier: 'l0' (id+abstract only, ~10x smaller) or 'full' (LOD-packed bodies). HTTP default: full. MCP default: l0."),
        ],
        handler: { ctx in
            let rawTopic = try ctx.params.require("topic")
            let topic = rawTopic.replacingOccurrences(of: "+", with: " ")
            let budget = ctx.params.int("budget") ?? 8000
            let limit = ctx.params.int("limit") ?? 20
            let project = ctx.params.string("project")
            let filterTopic = ctx.params.string("filterTopic")
            let wanderEnabled = (ctx.params.string("wander") ?? "true") != "false"
            let tierParam = (ctx.params.string("tier") ?? "full").lowercased()
            let tier = (tierParam == "l0") ? "l0" : "full"

            let dbPool = ctx.dbPool
            let t0 = DispatchTime.now()
            var timings: [String: Int] = [:]

            do {
                // Concurrent: Wiki search (MeiliSearch)
                let wikiTask: Task<[WikiPageResultAction], Never> = Task {
                    await recallSearchWiki(query: topic, limit: 3, search: ctx.search)
                }

                // Concurrent: Vector search
                let vectorTask: Task<[String: Double], Never> = Task {
                    do {
                        // local nomic or OpenRouter per EmbeddingProvider.current; any
                        // failure (e.g. no key) falls back to empty → keyword recall.
                        let queryEmbedding = try await embedText(topic, isQuery: true)
                        let rows: [(String, Data)] = try await dbPool.read { db in
                            try Row.fetchAll(db, sql: "SELECT memoryId, embedding FROM memoryEmbeddings")
                                .map { row in (row["memoryId"] as String, row["embedding"] as Data) }
                        }
                        guard !rows.isEmpty else { return [:] }
                        // Mean-center for anisotropic local embeddings (nomic) so
                        // cosine actually discriminates; no-op for OpenRouter.
                        let corpus = rows.map { ($0.0, unpackFloats($0.1)) }
                        let doCenter = embeddingNeedsCentering
                        let mu = doCenter ? corpusMean(corpus.map { $0.1 }) : []
                        let q = doCenter ? centeredVector(queryEmbedding, by: mu) : queryEmbedding
                        var scores: [String: Double] = [:]
                        for (memoryId, emb) in corpus {
                            let v = doCenter ? centeredVector(emb, by: mu) : emb
                            let sim = Double(cosineSimilarity(q, v))
                            if sim > 0.3 {
                                scores[memoryId] = sim
                            }
                        }
                        return scores
                    } catch {
                        return [:]
                    }
                }

                // Phase 1: text-based strategies
                let phase1Result = try await dbPool.read { db -> Phase1ResultAction in
                    let memories = try recallFtsSearchMemories(
                        db: db, query: topic, limit: limit,
                        project: project, filterTopic: filterTopic
                    )

                    let entitySearch = try recallFtsSearchEntities(db: db, query: topic, limit: 5)

                    var exactEntities: [EntityRow] = []
                    if let exact = try EntityRow.fetchOne(
                        db,
                        sql: "SELECT * FROM entities WHERE name = ? COLLATE NOCASE",
                        arguments: [topic]
                    ) {
                        exactEntities.append(exact)
                    }
                    let words = topic.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
                        .map(String.init)
                    let existingExactIds = Set(exactEntities.map(\.id))
                    for word in words where word != topic {
                        if let exact = try EntityRow.fetchOne(
                            db,
                            sql: "SELECT * FROM entities WHERE name = ? COLLATE NOCASE",
                            arguments: [word]
                        ), !existingExactIds.contains(exact.id) {
                            exactEntities.append(exact)
                        }
                    }
                    let exactEntity: EntityRow? = exactEntities.first

                    let documents = try recallFtsSearchDocuments(db: db, query: topic, limit: 5)

                    return Phase1ResultAction(
                        memories: memories,
                        entitySearch: entitySearch,
                        exactEntity: exactEntity,
                        exactEntities: exactEntities,
                        documents: documents
                    )
                }

                timings["phase1"] = recallMsElapsed(since: t0)

                let tv = DispatchTime.now()
                let vectorScores = await vectorTask.value
                timings["vectorSearch"] = recallMsElapsed(since: tv)
                timings["vectorHits"] = vectorScores.count

                let tw = DispatchTime.now()
                let wikiResults = await wikiTask.value
                timings["wikiSpotlight"] = recallMsElapsed(since: tw)
                timings["wikiHits"] = wikiResults.count

                let wanderAnchors = Array(phase1Result.memories.prefix(3))
                let capturedVectorScores = vectorScores
                let wanderTask: Task<(temporal: [WanderMemoryAction], graph: [WanderMemoryAction], periphery: [WanderMemoryAction]), Never>? =
                    wanderEnabled && !wanderAnchors.isEmpty ? Task {
                        await recallWanderFromAnchors(
                            anchors: wanderAnchors,
                            vectorScores: capturedVectorScores,
                            dbPool: dbPool,
                            perStrategy: 3
                        )
                    } : nil

                var entities = phase1Result.entitySearch
                for exact in phase1Result.exactEntities {
                    if !entities.contains(where: { $0.id == exact.id }) {
                        entities.insert(exact, at: 0)
                    }
                }

                // Phase 2: graph traversal depth-1
                let t2 = DispatchTime.now()
                var relatedMemoryIds = Set<String>()
                var allRelations: [RelationRow] = []
                let hop1EntityIds = Set(entities.map(\.id))
                var hop2Entities: [(id: String, via: String)] = []

                let entitiesSnapshot = entities
                let depth1Results = try await dbPool.read { db -> [[RelationRow]] in
                    try entitiesSnapshot.map { entity in
                        try recallFetchRelations(db: db, id: entity.id, type: "entity")
                    }
                }

                for relations in depth1Results {
                    allRelations.append(contentsOf: relations)
                    for rel in relations {
                        if rel.targetType == "memory" { relatedMemoryIds.insert(rel.targetId) }
                        if rel.sourceType == "memory" { relatedMemoryIds.insert(rel.sourceId) }
                        if rel.targetType == "entity" && !hop1EntityIds.contains(rel.targetId) {
                            hop2Entities.append((id: rel.targetId, via: rel.relation))
                        }
                        if rel.sourceType == "entity" && !hop1EntityIds.contains(rel.sourceId) {
                            hop2Entities.append((id: rel.sourceId, via: rel.relation))
                        }
                    }
                }

                timings["phase2"] = recallMsElapsed(since: t2)

                // Phase 3: depth-2 + fetch related memories
                let t3 = DispatchTime.now()
                let existingIds = Set(phase1Result.memories.map(\.id))

                var hop2Visited = Set<String>()
                let uniqueHop2 = hop2Entities.prefix(5).filter { h in
                    if hop2Visited.contains(h.id) { return false }
                    hop2Visited.insert(h.id)
                    return true
                }

                let depth2Results = try await dbPool.read { db -> [(relations: [RelationRow], entity: EntityRow?)] in
                    try uniqueHop2.map { hop2 in
                        let rels = try recallFetchRelations(db: db, id: hop2.id, type: "entity")
                        let ent = try EntityRow.fetchOne(
                            db,
                            sql: "SELECT * FROM entities WHERE id = ?",
                            arguments: [hop2.id]
                        )
                        return (relations: rels, entity: ent)
                    }
                }

                for result in depth2Results {
                    for rel in result.relations {
                        if rel.targetType == "memory" { relatedMemoryIds.insert(rel.targetId) }
                        if rel.sourceType == "memory" { relatedMemoryIds.insert(rel.sourceId) }
                        if !allRelations.contains(where: { $0.id == rel.id }) {
                            allRelations.append(rel)
                        }
                    }
                    if let ent = result.entity, !entities.contains(where: { $0.id == ent.id }) {
                        entities.append(ent)
                    }
                }

                let maxGraphMemories = 20
                var allFoundIds = existingIds
                var memoryIdsToFetch: [String] = []
                var graphCount = 0
                var graphPartial = false

                for memId in relatedMemoryIds {
                    if graphCount >= maxGraphMemories {
                        if !allFoundIds.contains(memId) { graphPartial = true }
                        break
                    }
                    if !allFoundIds.contains(memId) {
                        allFoundIds.insert(memId)
                        memoryIdsToFetch.append(memId)
                        graphCount += 1
                    }
                }

                timings["phase3a_depth2AndVector"] = recallMsElapsed(since: t3)
                timings["phase3b_memoriesToFetch"] = memoryIdsToFetch.count

                let t3b = DispatchTime.now()
                let idsToFetch = memoryIdsToFetch
                let additionalMemories: [MemoryRow] = try await dbPool.read { db in
                    guard !idsToFetch.isEmpty else { return [] }
                    let placeholders = idsToFetch.map { _ in "?" }.joined(separator: ",")
                    return try MemoryRow.fetchAll(
                        db,
                        sql: "SELECT * FROM memories WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(idsToFetch)
                    )
                }

                timings["phase3b_fetchTime"] = recallMsElapsed(since: t3b)

                // Vector-only memories
                let allFoundMemoryIds = Set(phase1Result.memories.map(\.id))
                    .union(additionalMemories.map(\.id))
                let vectorOnlyIds = vectorScores.keys.filter { !allFoundMemoryIds.contains($0) }

                let vectorOnlyMemories: [MemoryRow] = try await dbPool.read { db in
                    guard !vectorOnlyIds.isEmpty else { return [] }
                    let placeholders = vectorOnlyIds.map { _ in "?" }.joined(separator: ",")
                    return try MemoryRow.fetchAll(
                        db,
                        sql: "SELECT * FROM memories WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(Array(vectorOnlyIds))
                    )
                }

                // Combine and score
                let now = nowMs()
                var allScoredMemories: [ScoredMemoryAction] = []

                for (i, mem) in phase1Result.memories.enumerated() {
                    allScoredMemories.append(ScoredMemoryAction(
                        row: mem, searchRank: i,
                        rankScore: recallScoreMemory(mem, searchRank: i, now: now, vectorScore: vectorScores[mem.id])
                    ))
                }

                for (i, mem) in additionalMemories.enumerated() {
                    guard !existingIds.contains(mem.id) else { continue }
                    let rank = phase1Result.memories.count + i
                    allScoredMemories.append(ScoredMemoryAction(
                        row: mem, searchRank: rank,
                        rankScore: recallScoreMemory(mem, searchRank: rank, now: now, vectorScore: vectorScores[mem.id])
                    ))
                }

                for mem in vectorOnlyMemories {
                    allScoredMemories.append(ScoredMemoryAction(
                        row: mem, searchRank: 999,
                        rankScore: recallScoreMemory(mem, searchRank: 999, now: now, vectorScore: vectorScores[mem.id])
                    ))
                }

                let filtered = allScoredMemories.filter { scored in
                    let m = scored.row
                    if let status = m.status, status != "active" { return false }
                    if let until = m.validUntil, until <= now { return false }
                    return true
                }

                let namespacedFiltered: [ScoredMemoryAction]
                if project != nil || filterTopic != nil {
                    namespacedFiltered = filtered.filter { scored in
                        let m = scored.row
                        if let p = project, m.project != p { return false }
                        if let ft = filterTopic, m.topic != ft { return false }
                        return true
                    }
                } else {
                    namespacedFiltered = filtered
                }

                let sorted = namespacedFiltered.sorted { $0.rankScore > $1.rankScore }

                timings["phase3"] = recallMsElapsed(since: t3)
                timings["memoryCount"] = phase1Result.memories.count
                timings["vectorOnlyCount"] = vectorOnlyMemories.count

                // Reserve a slice of the budget for wiki pages (curated knowledge gets priority).
                // Pack wiki pages first up to wikiBudget; memories/entities/relations/docs then pack
                // into the remainder so high-volume memory hits can't push wiki results out.
                let wikiBudget = min(2000, budget / 4)
                var finalWiki: [WikiPageResultAction] = []
                var wikiTokens = 0
                for page in wikiResults {
                    let pageJSON = (try? JSONEncoder().encode([page])) ?? Data()
                    let pageTokens = recallEstimateTokens(String(data: pageJSON, encoding: .utf8) ?? "")
                    if wikiTokens + pageTokens > wikiBudget { break }
                    finalWiki.append(page)
                    wikiTokens += pageTokens
                }
                let memoryBudget = budget - wikiTokens

                // Budget-aware packing — branches by tier.
                // tier=l0:   id + l0 abstract only. ~10x smaller per memory.
                // tier=full: today's LOD ladder (full → l1 → l0) up to budget.
                var used = 0
                var included: [RecallMemoryAction] = []

                if tier == "l0" {
                    for scored in sorted {
                        let mem = scored.row
                        let tags = parseTags(mem.tagsJSON)
                        let l0Text = mem.l0 ?? String(mem.content.prefix(80))
                        let l0Repr = "{\"_id\":\"\(mem.id)\",\"type\":\"\(mem.type)\",\"l0\":\"\(l0Text)\",\"importance\":\(mem.importance)}"
                        let l0Tokens = recallEstimateTokens(l0Repr)
                        if used + l0Tokens > memoryBudget { break }
                        included.append(recallMakeRecallMemory(
                            mem, tags: tags, searchRank: scored.searchRank,
                            rankScore: scored.rankScore, tier: "l0", includeContent: false,
                            overrideL0: l0Text
                        ))
                        used += l0Tokens
                    }
                } else {
                    for scored in sorted {
                        let mem = scored.row
                        let tags = parseTags(mem.tagsJSON)

                        let l0Text = mem.l0 ?? String(mem.content.prefix(80))
                        let l0Repr = "{\"_id\":\"\(mem.id)\",\"type\":\"\(mem.type)\",\"l0\":\"\(l0Text)\",\"importance\":\(mem.importance)}"
                        let l0Tokens = recallEstimateTokens(l0Repr)

                        if used + l0Tokens > memoryBudget { break }

                        let fullJSON = recallEncodeMemoryForBudget(mem, tags: tags)
                        let fullTokens = recallEstimateTokens(fullJSON)

                        if used + fullTokens <= memoryBudget {
                            included.append(recallMakeRecallMemory(
                                mem, tags: tags, searchRank: scored.searchRank,
                                rankScore: scored.rankScore, tier: "full", includeContent: true
                            ))
                            used += fullTokens
                            continue
                        }

                        let l1Text = mem.l1 ?? String(mem.content.prefix(250))
                        let l1Repr = "{\"_id\":\"\(mem.id)\",\"type\":\"\(mem.type)\",\"l0\":\"\(l0Text)\",\"l1\":\"\(l1Text)\",\"importance\":\(mem.importance),\"source\":\"\(mem.source ?? "")\"}"
                        let l1Tokens = recallEstimateTokens(l1Repr)

                        if used + l1Tokens <= memoryBudget {
                            included.append(recallMakeRecallMemory(
                                mem, tags: tags, searchRank: scored.searchRank,
                                rankScore: scored.rankScore, tier: "l1", includeContent: false,
                                overrideL0: l0Text, overrideL1: l1Text
                            ))
                            used += l1Tokens
                            continue
                        }

                        included.append(recallMakeRecallMemory(
                            mem, tags: tags, searchRank: scored.searchRank,
                            rankScore: scored.rankScore, tier: "l0", includeContent: false,
                            overrideL0: l0Text
                        ))
                        used += l0Tokens
                    }
                }

                // Entities within memory budget
                let entityResponses = entities.map(entityRowToResponse)
                let entityJSON = (try? JSONEncoder().encode(entityResponses)) ?? Data()
                let entityTokens = recallEstimateTokens(String(data: entityJSON, encoding: .utf8) ?? "")
                let finalEntities = (used + entityTokens <= memoryBudget) ? entityResponses : []
                if !finalEntities.isEmpty { used += entityTokens }

                // Relations within memory budget
                let relationResponses = allRelations.map(relationRowToResponse)
                let relationJSON = (try? JSONEncoder().encode(relationResponses)) ?? Data()
                let relationTokens = recallEstimateTokens(String(data: relationJSON, encoding: .utf8) ?? "")
                let finalRelations = (used + relationTokens <= memoryBudget) ? relationResponses : []
                if !finalRelations.isEmpty { used += relationTokens }

                // Documents within memory budget
                let docSummaries = phase1Result.documents.map { d in
                    DocumentSummaryAction(
                        _id: d.id, title: d.title, path: d.path,
                        docType: d.docType, project: d.project,
                        status: d.status, tags: parseTags(d.tagsJSON),
                        summary: d.summary, updatedAt: d.updatedAt
                    )
                }
                let docJSON = (try? JSONEncoder().encode(docSummaries)) ?? Data()
                let docTokens = recallEstimateTokens(String(data: docJSON, encoding: .utf8) ?? "")
                let finalDocs = (used + docTokens <= memoryBudget) ? docSummaries : []
                if !finalDocs.isEmpty { used += docTokens }

                // Wiki was pre-packed into finalWiki above; account for its tokens against the total.
                used += wikiTokens

                // Wander (separate from main budget)
                let twander = DispatchTime.now()
                var finalWander: [WanderMemoryAction] = []
                var finalWanderCount = 0
                if let wanderTask = wanderTask {
                    let wanderResult = await wanderTask.value
                    let allWander = wanderResult.temporal + wanderResult.graph + wanderResult.periphery
                    finalWander = allWander
                    finalWanderCount = allWander.count
                    let wanderJSON = (try? JSONEncoder().encode(allWander)) ?? Data()
                    let wanderTokens = recallEstimateTokens(String(data: wanderJSON, encoding: .utf8) ?? "")
                    used += wanderTokens
                    timings["wanderTemporal"] = wanderResult.temporal.count
                    timings["wanderGraph"] = wanderResult.graph.count
                    timings["wanderPeriphery"] = wanderResult.periphery.count
                }
                timings["wanderTotal"] = recallMsElapsed(since: twander)
                timings["wanderCount"] = finalWanderCount

                // Touch accessed memories (fire-and-forget)
                let touchIds = included.prefix(10).map(\._id)
                if !touchIds.isEmpty {
                    Task {
                        try? await dbPool.write { db in
                            let touchNow = nowMs()
                            for id in touchIds {
                                try db.execute(
                                    sql: """
                                    UPDATE memories
                                    SET accessCount = COALESCE(accessCount, 0) + 1,
                                        lastAccessedAt = ?
                                    WHERE id = ?
                                    """,
                                    arguments: [touchNow, id]
                                )
                            }
                        }
                    }
                }

                timings["total"] = recallMsElapsed(since: t0)

                let budgetCapHit = included.count < sorted.count
                let unreturnedCandidates = sorted.count - included.count
                let partial = budgetCapHit || graphPartial

                return RecallResponseAction(
                    memories: included,
                    entities: finalEntities,
                    relations: finalRelations,
                    documents: finalDocs,
                    wikiPages: finalWiki,
                    wander: finalWander,
                    wanderCount: finalWanderCount,
                    query: topic,
                    vectorResultCount: vectorScores.count,
                    partial: partial,
                    tokenUsage: TokenUsageAction(
                        budget: budget,
                        used: used,
                        memoriesIncluded: included.count,
                        memoriesTotal: sorted.count,
                        truncated: budgetCapHit,
                        tier: tier,
                        unreturnedCandidates: max(0, unreturnedCandidates)
                    ),
                    _timings: timings
                )
            } catch {
                throw ActionError.custom("Recall failed: \(error.localizedDescription)", .internalServerError)
            }
        }
    ),

    // GET /api/recall/fetch — pure id-keyed body fetch (no re-ranking, no search).
    // Companion to tier=l0 mem_recall: caller picks ids of interest from the l0
    // summary, then expands them in one round-trip.
    SonataAction(
        name: "mem_fetch_full",
        description: "Fetch full memory bodies by id list. No ranking, no search — pure batch read. Pair with tier=l0 mem_recall: get summaries, pick ids, expand them here.",
        group: "/api/recall",
        path: "/fetch",
        method: .get,
        params: [
            ActionParam("ids", .stringArray, required: true, description: "Memory ids (comma-separated or JSON array)"),
        ],
        handler: { ctx in
            guard let ids = ctx.params.stringArray("ids"), !ids.isEmpty else {
                throw ActionError.custom("ids is required and must be non-empty", .badRequest)
            }
            let dbPool = ctx.dbPool
            let rows: [MemoryRow] = try await dbPool.read { db in
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                return try MemoryRow.fetchAll(
                    db,
                    sql: "SELECT * FROM memories WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(ids)
                )
            }
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            var memories: [RecallMemoryAction] = []
            for id in ids {
                guard let mem = byId[id] else { continue }
                let tags = parseTags(mem.tagsJSON)
                memories.append(recallMakeRecallMemory(
                    mem, tags: tags, searchRank: 0, rankScore: 0,
                    tier: "full", includeContent: true
                ))
            }
            return FetchFullResponse(
                memories: memories,
                requested: ids.count,
                found: memories.count
            )
        }
    ),

    // GET /api/recall/doc-search — full-text search across wiki pages and archived memories via MeiliSearch
    SonataAction(
        name: "mem_doc_search",
        description: "Full-text search across wiki pages and archived memories.",
        group: "/api/recall",
        path: "/doc-search",
        method: .get,
        params: [
            ActionParam("q", .string, required: true, description: "Search query"),
            ActionParam("index", .string, description: "Index: wiki, archive, docs, private, or all (default: all)"),
            ActionParam("limit", .integer, description: "Max results (default 5)"),
        ],
        handler: { ctx in
            guard let search = ctx.search else {
                throw ActionError.custom("Search service not available", .internalServerError)
            }
            let q = try ctx.params.require("q")
            let index = ctx.params.string("index") ?? "all"
            let limit = ctx.params.int("limit") ?? 5

            let results: [SearchResult]
            switch index {
            case "wiki":
                results = await search.searchWiki(query: q, limit: limit)
            case "archive":
                results = await search.searchArchive(query: q, limit: limit)
            case "docs":
                results = await search.searchDocs(query: q, limit: limit)
            case "private":
                results = await search.searchPrivate(query: q, limit: limit)
            default:
                results = await search.search(query: q, limit: limit)
            }

            return results.map { r in
                DocSearchResultResponse(
                    id: r.id,
                    title: r.title,
                    snippet: r.snippet,
                    index: r.index
                )
            }
        }
    ),
]
