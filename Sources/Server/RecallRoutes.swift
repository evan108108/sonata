import Foundation
import Hummingbird
import GRDB
#if canImport(Accelerate)
import Accelerate
#endif

// MARK: - Token estimation

/// Approximation: ~4 chars per token for English text (matches OpenAI tokenizer within ~10%)
private func estimateTokens(_ text: String) -> Int {
    (text.count + 3) / 4
}

// MARK: - Scoring

/// Score a memory for ranking in budget-aware recall.
/// Weights: searchRelevance(25%) + vectorSimilarity(25%) + importance(20%) + recency(15%) + accessScore(5%).
/// When vector search is unavailable, FTS weight increases to 40% to compensate.
private func scoreMemory(_ mem: MemoryRow, searchRank: Int, now: Int64, vectorScore: Double? = nil) -> Double {
    let importance = mem.importance
    let ageHours = Double(now - mem.createdAt) / (1000 * 60 * 60)
    let recencyScore = max(0.0, 1.0 - ageHours / (24 * 30)) // decays over 30 days
    let accessScore = min(1.0, Double(mem.accessCount ?? 0) / 20.0) // caps at 20
    let searchRelevance = max(0.0, 1.0 - Double(searchRank) / 30.0) // top 30 get bonus

    if let vs = vectorScore {
        // Full 7-strategy scoring
        return searchRelevance * 0.25
            + vs * 0.25
            + (importance / 10.0) * 0.20
            + recencyScore * 0.15
            + accessScore * 0.05
    } else {
        // No vector score — redistribute vector weight to FTS
        return searchRelevance * 0.40
            + (importance / 10.0) * 0.20
            + recencyScore * 0.15
            + accessScore * 0.05
    }
}

// MARK: - Response Types

/// Recall memory with scoring/tier metadata
private struct RecallMemory: Encodable {
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

/// Document summary (stripped of content)
private struct DocumentSummary: Encodable {
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

/// Wiki page found via Spotlight search on disk
private struct WikiPageResult: Encodable {
    let slug: String
    let title: String
    let snippet: String  // first ~500 chars of content
    let path: String
}

/// Memory surfaced by wander (accidental adjacency)
private struct WanderMemory: Encodable {
    let _id: String
    let type: String
    let l0: String?
    let content: String?  // first 100 chars
    let importance: Double
    let createdAt: Int64
    let _adjacency: String  // "temporal" | "graph" | "periphery"
    let _anchorId: String?
    let _anchorSummary: String?
    let _gapMinutes: Int?      // temporal only
    let _viaEntity: String?    // graph only
    let _relation: String?     // graph only
    let _score: Double?        // periphery only
}

private struct TokenUsage: Encodable {
    let budget: Int
    let used: Int
    let memoriesIncluded: Int
    let memoriesTotal: Int
    let truncated: Bool
}

private struct RecallResponse: Encodable {
    let memories: [RecallMemory]
    let entities: [EntityResponse]
    let relations: [RelationResponse]
    let documents: [DocumentSummary]
    let wikiPages: [WikiPageResult]
    let wander: [WanderMemory]
    let wanderCount: Int
    let query: String
    let vectorResultCount: Int
    let tokenUsage: TokenUsage
    let _timings: [String: Int]
}

// MARK: - Internal scored memory container

private struct ScoredMemory {
    let row: MemoryRow
    let searchRank: Int
    let rankScore: Double
}

// MARK: - Route Registration

public func registerRecallRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    // GET /api/recall?topic=&budget=&limit=&project=&filterTopic=
    router.get("/api/recall") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let rawTopic = queryParams["topic"].map(String.init), !rawTopic.isEmpty else {
            return errorResponse("topic parameter is required")
        }
        // Hummingbird doesn't decode '+' as space in query params (only %20)
        let topic = rawTopic.replacingOccurrences(of: "+", with: " ")
        let budget = Int(queryParams["budget"] ?? "") ?? 8000
        let limit = Int(queryParams["limit"] ?? "") ?? 20
        let project = queryParams["project"].map(String.init)
        let filterTopic = queryParams["filterTopic"].map(String.init)
        let wanderEnabled = (queryParams["wander"].map(String.init) ?? "true") != "false"

        let t0 = DispatchTime.now()
        var timings: [String: Int] = [:]

        do {
            // === Wiki Spotlight search (runs concurrently with Phase 1) ===
            // Strategy 5b: macOS Spotlight search on wiki markdown files on disk
            let wikiTask: Task<[WikiPageResult], Never> = Task {
                await spotlightSearchWiki(query: topic, limit: 3)
            }

            // === Vector search (runs concurrently with Phase 1) ===
            // Strategy 7: Semantic similarity via embeddings
            let vectorTask: Task<[String: Double], Never> = Task {
                guard let apiKey = SecretStore.get("OPENROUTER_API_KEY"), !apiKey.isEmpty else {
                    return [:]
                }
                do {
                    let queryEmbedding = try await generateEmbedding(text: topic, apiKey: apiKey)
                    let rows: [(String, Data)] = try await dbPool.read { db in
                        try Row.fetchAll(db, sql: "SELECT memoryId, embedding FROM memoryEmbeddings")
                            .map { row in (row["memoryId"] as String, row["embedding"] as Data) }
                    }
                    guard !rows.isEmpty else { return [:] }
                    var scores: [String: Double] = [:]
                    for (memoryId, blob) in rows {
                        let emb = unpackFloats(blob)
                        let sim = Double(cosineSimilarity(queryEmbedding, emb))
                        if sim > 0.3 { // threshold: ignore weak matches
                            scores[memoryId] = sim
                        }
                    }
                    return scores
                } catch {
                    return [:]
                }
            }

            // === Phase 1: Parallel text-based strategies ===
            let phase1Result = try await dbPool.read { db -> Phase1Result in
                // Strategy 1: FTS5 search on memories
                let memories = try ftsSearchMemories(
                    db: db, query: topic, limit: limit,
                    project: project, filterTopic: filterTopic
                )

                // Strategy 2: FTS5 search on entities
                let entitySearch = try ftsSearchEntities(db: db, query: topic, limit: 5)

                // Strategy 3: Exact entity name lookup (full topic + individual words)
                var exactEntities: [EntityRow] = []
                // Try full topic as exact name
                if let exact = try EntityRow.fetchOne(
                    db,
                    sql: "SELECT * FROM entities WHERE name = ? COLLATE NOCASE",
                    arguments: [topic]
                ) {
                    exactEntities.append(exact)
                }
                // Also try each individual word as entity name (e.g. "Evan" from "Evan preferences")
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

                // Strategy 5: Document search via FTS5
                let documents = try ftsSearchDocuments(db: db, query: topic, limit: 5)

                return Phase1Result(
                    memories: memories,
                    entitySearch: entitySearch,
                    exactEntity: exactEntity,
                    exactEntities: exactEntities,
                    documents: documents
                )
            }

            timings["phase1"] = msElapsed(since: t0)

            // Await concurrent results (wiki Spotlight + vector search)
            let tv = DispatchTime.now()
            let vectorScores = await vectorTask.value
            timings["vectorSearch"] = msElapsed(since: tv)
            timings["vectorHits"] = vectorScores.count

            let tw = DispatchTime.now()
            let wikiResults = await wikiTask.value
            timings["wikiSpotlight"] = msElapsed(since: tw)
            timings["wikiHits"] = wikiResults.count

            // Launch wander concurrently (needs Phase 1 anchors + vectorScores)
            let wanderAnchors = Array(phase1Result.memories.prefix(3))
            let capturedVectorScores = vectorScores
            let wanderTask: Task<(temporal: [WanderMemory], graph: [WanderMemory], periphery: [WanderMemory]), Never>? =
                wanderEnabled && !wanderAnchors.isEmpty ? Task {
                    await wanderFromAnchors(
                        anchors: wanderAnchors,
                        vectorScores: capturedVectorScores,
                        dbPool: dbPool,
                        perStrategy: 3
                    )
                } : nil

            // Merge exact entities into search results
            var entities = phase1Result.entitySearch
            for exact in phase1Result.exactEntities {
                if !entities.contains(where: { $0.id == exact.id }) {
                    entities.insert(exact, at: 0)
                }
            }

            // === Phase 2: Graph traversal depth-1 ===
            let t2 = DispatchTime.now()
            var relatedMemoryIds = Set<String>()
            var allRelations: [RelationRow] = []
            let hop1EntityIds = Set(entities.map(\.id))
            var hop2Entities: [(id: String, via: String)] = []

            let depth1Results = try await dbPool.read { db -> [[RelationRow]] in
                try entities.map { entity in
                    try fetchRelations(db: db, id: entity.id, type: "entity")
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

            timings["phase2"] = msElapsed(since: t2)

            // === Phase 3: Depth-2 traversal + fetch related memories ===
            let t3 = DispatchTime.now()
            let existingIds = Set(phase1Result.memories.map(\.id))

            // Depth-2: follow relations from connected entities (capped at 5, deduped)
            var hop2Visited = Set<String>()
            let uniqueHop2 = hop2Entities.prefix(5).filter { h in
                if hop2Visited.contains(h.id) { return false }
                hop2Visited.insert(h.id)
                return true
            }

            let depth2Results = try await dbPool.read { db -> [(relations: [RelationRow], entity: EntityRow?)] in
                try uniqueHop2.map { hop2 in
                    let rels = try fetchRelations(db: db, id: hop2.id, type: "entity")
                    let ent = try EntityRow.fetchOne(
                        db,
                        sql: "SELECT * FROM entities WHERE id = ?",
                        arguments: [hop2.id]
                    )
                    return (relations: rels, entity: ent)
                }
            }

            // Process depth-2 results
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

            // Cap graph-related memories at 20
            let maxGraphMemories = 20
            var allFoundIds = existingIds
            var memoryIdsToFetch: [String] = []
            var graphCount = 0

            for memId in relatedMemoryIds {
                if graphCount >= maxGraphMemories { break }
                if !allFoundIds.contains(memId) {
                    allFoundIds.insert(memId)
                    memoryIdsToFetch.append(memId)
                    graphCount += 1
                }
            }

            timings["phase3a_depth2AndVector"] = msElapsed(since: t3)
            timings["phase3b_memoriesToFetch"] = memoryIdsToFetch.count

            // Batch-fetch additional memories
            let t3b = DispatchTime.now()
            let additionalMemories: [MemoryRow] = try await dbPool.read { db in
                guard !memoryIdsToFetch.isEmpty else { return [] }
                let placeholders = memoryIdsToFetch.map { _ in "?" }.joined(separator: ",")
                return try MemoryRow.fetchAll(
                    db,
                    sql: "SELECT * FROM memories WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(memoryIdsToFetch)
                )
            }

            timings["phase3b_fetchTime"] = msElapsed(since: t3b)

            // === Fetch vector-only memories (found by embeddings but not by FTS/graph) ===
            var allFoundMemoryIds = Set(phase1Result.memories.map(\.id))
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

            // === Combine all memories ===
            let now = nowMs()

            // Tag memories with search rank + vector score
            var allScoredMemories: [ScoredMemory] = []

            for (i, mem) in phase1Result.memories.enumerated() {
                allScoredMemories.append(ScoredMemory(
                    row: mem, searchRank: i,
                    rankScore: scoreMemory(mem, searchRank: i, now: now, vectorScore: vectorScores[mem.id])
                ))
            }

            for (i, mem) in additionalMemories.enumerated() {
                // Skip if already in text search results
                guard !existingIds.contains(mem.id) else { continue }
                let rank = phase1Result.memories.count + i
                allScoredMemories.append(ScoredMemory(
                    row: mem, searchRank: rank,
                    rankScore: scoreMemory(mem, searchRank: rank, now: now, vectorScore: vectorScores[mem.id])
                ))
            }

            // Add vector-only memories (no FTS rank, scored purely on vector + metadata)
            for mem in vectorOnlyMemories {
                allScoredMemories.append(ScoredMemory(
                    row: mem, searchRank: 999,
                    rankScore: scoreMemory(mem, searchRank: 999, now: now, vectorScore: vectorScores[mem.id])
                ))
            }

            // Filter out superseded/archived and expired
            let filtered = allScoredMemories.filter { scored in
                let m = scored.row
                if let status = m.status, status != "active" { return false }
                if let until = m.validUntil, until <= now { return false }
                return true
            }

            // Post-filter by namespace
            let namespacedFiltered: [ScoredMemory]
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

            // Sort by score descending
            let sorted = namespacedFiltered.sorted { $0.rankScore > $1.rankScore }

            timings["phase3"] = msElapsed(since: t3)
            timings["memoryCount"] = phase1Result.memories.count
            timings["vectorOnlyCount"] = vectorOnlyMemories.count

            // === Budget-aware LOD packing ===
            var used = 0
            var included: [RecallMemory] = []

            for scored in sorted {
                let mem = scored.row
                let tags = parseTags(mem.tagsJSON)

                // Try l0 first (cheapest) to see if we can fit at all
                let l0Text = mem.l0 ?? String(mem.content.prefix(80))
                let l0Repr = "{\"_id\":\"\(mem.id)\",\"type\":\"\(mem.type)\",\"l0\":\"\(l0Text)\",\"importance\":\(mem.importance)}"
                let l0Tokens = estimateTokens(l0Repr)

                if used + l0Tokens > budget { break }

                // Try full content
                let fullJSON = encodeMemoryForBudget(mem, tags: tags)
                let fullTokens = estimateTokens(fullJSON)

                if used + fullTokens <= budget {
                    included.append(makeRecallMemory(
                        mem, tags: tags, searchRank: scored.searchRank,
                        rankScore: scored.rankScore, tier: "full", includeContent: true
                    ))
                    used += fullTokens
                    continue
                }

                // Try l1
                let l1Text = mem.l1 ?? String(mem.content.prefix(250))
                let l1Repr = "{\"_id\":\"\(mem.id)\",\"type\":\"\(mem.type)\",\"l0\":\"\(l0Text)\",\"l1\":\"\(l1Text)\",\"importance\":\(mem.importance),\"source\":\"\(mem.source ?? "")\"}"
                let l1Tokens = estimateTokens(l1Repr)

                if used + l1Tokens <= budget {
                    included.append(makeRecallMemory(
                        mem, tags: tags, searchRank: scored.searchRank,
                        rankScore: scored.rankScore, tier: "l1", includeContent: false,
                        overrideL0: l0Text, overrideL1: l1Text
                    ))
                    used += l1Tokens
                    continue
                }

                // Fall back to l0
                included.append(makeRecallMemory(
                    mem, tags: tags, searchRank: scored.searchRank,
                    rankScore: scored.rankScore, tier: "l0", includeContent: false,
                    overrideL0: l0Text
                ))
                used += l0Tokens
            }

            // Include entities if budget allows
            let entityResponses = entities.map(entityRowToResponse)
            let entityJSON = (try? JSONEncoder().encode(entityResponses)) ?? Data()
            let entityTokens = estimateTokens(String(data: entityJSON, encoding: .utf8) ?? "")
            let finalEntities = (used + entityTokens <= budget) ? entityResponses : []
            if !finalEntities.isEmpty { used += entityTokens }

            // Include relations if budget allows
            let relationResponses = allRelations.map(relationRowToResponse)
            let relationJSON = (try? JSONEncoder().encode(relationResponses)) ?? Data()
            let relationTokens = estimateTokens(String(data: relationJSON, encoding: .utf8) ?? "")
            let finalRelations = (used + relationTokens <= budget) ? relationResponses : []
            if !finalRelations.isEmpty { used += relationTokens }

            // Include documents if budget allows
            let docSummaries = phase1Result.documents.map { d in
                DocumentSummary(
                    _id: d.id, title: d.title, path: d.path,
                    docType: d.docType, project: d.project,
                    status: d.status, tags: parseTags(d.tagsJSON),
                    summary: d.summary, updatedAt: d.updatedAt
                )
            }
            let docJSON = (try? JSONEncoder().encode(docSummaries)) ?? Data()
            let docTokens = estimateTokens(String(data: docJSON, encoding: .utf8) ?? "")
            let finalDocs = (used + docTokens <= budget) ? docSummaries : []
            if !finalDocs.isEmpty { used += docTokens }

            // Include wiki pages (from Spotlight) if budget allows
            let wikiJSON = (try? JSONEncoder().encode(wikiResults)) ?? Data()
            let wikiTokens = estimateTokens(String(data: wikiJSON, encoding: .utf8) ?? "")
            let finalWiki = (used + wikiTokens <= budget) ? wikiResults : []
            if !finalWiki.isEmpty { used += wikiTokens }

            // Await wander results — always included (separate from main budget, ~300 tokens max)
            let twander = DispatchTime.now()
            var finalWander: [WanderMemory] = []
            var finalWanderCount = 0
            if let wanderTask = wanderTask {
                let wanderResult = await wanderTask.value
                let allWander = wanderResult.temporal + wanderResult.graph + wanderResult.periphery
                finalWander = allWander
                finalWanderCount = allWander.count
                let wanderJSON = (try? JSONEncoder().encode(allWander)) ?? Data()
                let wanderTokens = estimateTokens(String(data: wanderJSON, encoding: .utf8) ?? "")
                used += wanderTokens
                timings["wanderTemporal"] = wanderResult.temporal.count
                timings["wanderGraph"] = wanderResult.graph.count
                timings["wanderPeriphery"] = wanderResult.periphery.count
            }
            timings["wanderTotal"] = msElapsed(since: twander)
            timings["wanderCount"] = finalWanderCount

            // Touch accessed memories (fire and forget, cap at 10)
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

            timings["total"] = msElapsed(since: t0)

            let response = RecallResponse(
                memories: included,
                entities: finalEntities,
                relations: finalRelations,
                documents: finalDocs,
                wikiPages: finalWiki,
                wander: finalWander,
                wanderCount: finalWanderCount,
                query: topic,
                vectorResultCount: vectorScores.count,
                tokenUsage: TokenUsage(
                    budget: budget,
                    used: used,
                    memoriesIncluded: included.count,
                    memoriesTotal: sorted.count,
                    truncated: included.count < sorted.count
                ),
                _timings: timings
            )

            return jsonResponse(response)
        } catch {
            return errorResponse("Recall failed: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}

// MARK: - Private Helpers

private struct Phase1Result {
    let memories: [MemoryRow]
    let entitySearch: [EntityRow]
    let exactEntity: EntityRow?
    let exactEntities: [EntityRow]
    let documents: [DocumentRow]
}

/// FTS5 search on memories table
private func ftsSearchMemories(
    db: Database, query: String, limit: Int,
    project: String?, filterTopic: String?
) throws -> [MemoryRow] {
    // Build FTS5-safe query: quote each word for prefix matching
    let ftsQuery = buildFTSQuery(query)
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

    // Only active, non-expired
    sql += " AND (m.status IS NULL OR m.status = 'active')"
    sql += " ORDER BY rank LIMIT ?"
    args.append(limit)

    return try MemoryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
}

/// FTS5 search on entities table.
/// Uses OR between tokens (matching Convex's OR-based search semantics)
/// so "Evan preferences" matches entities containing "Evan" OR "preferences".
private func ftsSearchEntities(db: Database, query: String, limit: Int) throws -> [EntityRow] {
    let ftsQuery = buildFTSQueryOR(query)
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

/// FTS5 search on documents table
private func ftsSearchDocuments(db: Database, query: String, limit: Int) throws -> [DocumentRow] {
    let ftsQuery = buildFTSQuery(query)
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

/// Build an FTS5 query from user input.
/// Quotes each token for safety (avoids syntax errors from special chars).
/// Uses implicit AND between tokens.
private func buildFTSQuery(_ input: String) -> String {
    let tokens = input.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
        .map { String($0) }
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return "" }
    // Quote each token and use * for prefix matching
    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
}

/// Build an FTS5 query with OR between tokens.
/// Used for entity search where we want broader matching (e.g. "Evan preferences"
/// should match entities containing "Evan" even if they don't contain "preferences").
private func buildFTSQueryOR(_ input: String) -> String {
    let tokens = input.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
        .map { String($0) }
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return "" }
    // Quote each token and use * for prefix matching, join with OR
    return tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
}

/// Fetch both incoming and outgoing relations for an id+type
private func fetchRelations(db: Database, id: String, type: String) throws -> [RelationRow] {
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

/// Milliseconds elapsed since a DispatchTime
private func msElapsed(since start: DispatchTime) -> Int {
    let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return Int(ns / 1_000_000)
}

/// Rough JSON size estimation for budget calculation
private func encodeMemoryForBudget(_ mem: MemoryRow, tags: [String]) -> String {
    // Approximate the full JSON size without actually encoding
    let tagsStr = tags.joined(separator: "\",\"")
    return """
    {"_id":"\(mem.id)","type":"\(mem.type)","content":"\(mem.content)","importance":\(mem.importance),"tags":["\(tagsStr)"],"source":"\(mem.source ?? "")","l0":"\(mem.l0 ?? "")","l1":"\(mem.l1 ?? "")","createdAt":\(mem.createdAt),"updatedAt":\(mem.updatedAt)}
    """
}

/// Create a RecallMemory from a MemoryRow with the given tier
private func makeRecallMemory(
    _ mem: MemoryRow,
    tags: [String],
    searchRank: Int,
    rankScore: Double,
    tier: String,
    includeContent: Bool,
    overrideL0: String? = nil,
    overrideL1: String? = nil
) -> RecallMemory {
    RecallMemory(
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

// MARK: - Wander (Accidental Adjacency)

/// Three strategies for surfacing unexpected connections:
/// A) Temporal neighbors — what was on your mind at the same time
/// B) Graph wander — follow the knowledge graph sideways from results
/// C) Embedding periphery — semantic neighbors that aren't top matches
private func wanderFromAnchors(
    anchors: [MemoryRow],
    vectorScores: [String: Double],
    dbPool: DatabasePool,
    perStrategy: Int = 3
) async -> (temporal: [WanderMemory], graph: [WanderMemory], periphery: [WanderMemory]) {
    let anchorIds = Set(anchors.map(\.id))

    // Strategy A: Temporal Neighbors — memories created within ±2h of anchors
    let temporal: [WanderMemory] = (try? await dbPool.read { db -> [WanderMemory] in
        let windowMs: Int64 = 2 * 60 * 60 * 1000  // ±2 hours
        var seen = anchorIds
        var results: [WanderMemory] = []

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
                results.append(WanderMemory(
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

    // Strategy B: Graph Wander — follow entity relations sideways
    let graph: [WanderMemory] = (try? await dbPool.read { db -> [WanderMemory] in
        var seen = anchorIds
        var results: [WanderMemory] = []

        for anchor in anchors.prefix(3) {
            // Find relations involving this anchor memory
            let rels = try fetchRelations(db: db, id: anchor.id, type: "memory")

            // Collect connected entity IDs
            var entityIds: [String] = []
            for rel in rels {
                if rel.targetType == "entity" && !entityIds.contains(rel.targetId) {
                    entityIds.append(rel.targetId)
                }
                if rel.sourceType == "entity" && !entityIds.contains(rel.sourceId) {
                    entityIds.append(rel.sourceId)
                }
            }

            // From those entities, find OTHER memories
            for entId in entityIds.prefix(3) {
                let entRels = try fetchRelations(db: db, id: entId, type: "entity")

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

                    // Look up entity name for context
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

                    results.append(WanderMemory(
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

    // Strategy C: Embedding Periphery — reuse vectorScores, skip top matches
    var periphery: [WanderMemory] = []
    if !vectorScores.isEmpty {
        // Sort by score descending, skip top 3 (exact matches)
        let sorted = vectorScores.sorted { $0.value > $1.value }
        let peripheryZone = Array(sorted.dropFirst(3).prefix(27))  // positions 4-30

        // Shuffle for serendipity
        let shuffled = peripheryZone.shuffled()

        // Sample up to perStrategy, excluding anchors
        var peripheryIds: [(String, Double)] = []
        for (memId, score) in shuffled {
            guard !anchorIds.contains(memId) else { continue }
            peripheryIds.append((memId, score))
            if peripheryIds.count >= perStrategy { break }
        }

        // Fetch memory rows
        if !peripheryIds.isEmpty {
            let fetched: [WanderMemory] = (try? await dbPool.read { db -> [WanderMemory] in
                var results: [WanderMemory] = []
                for (memId, score) in peripheryIds {
                    guard let mem = try MemoryRow.fetchOne(
                        db,
                        sql: "SELECT * FROM memories WHERE id = ? AND (status IS NULL OR status = 'active')",
                        arguments: [memId]
                    ) else { continue }

                    results.append(WanderMemory(
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

// MARK: - Spotlight Wiki Search

private let wikiDir = "/Users/evan/memory/wiki"

/// Search wiki markdown files on disk using macOS Spotlight (mdfind).
/// Returns WikiPageResult with slug, title (from first # heading), and snippet.
private func spotlightSearchWiki(query: String, limit: Int = 3) async -> [WikiPageResult] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["-onlyin", wikiDir, query]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return []
    }

    // Read output with a timeout
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
        return []
    }

    let paths = output.split(separator: "\n")
        .map(String.init)
        .filter { $0.hasSuffix(".md") }
        .prefix(limit)

    var results: [WikiPageResult] = []
    for path in paths {
        // Derive slug from path: /Users/evan/memory/wiki/adaptengine/mcp-server.md → adaptengine/mcp-server
        let relativePath = path.replacingOccurrences(of: wikiDir + "/", with: "")
        let slug = relativePath.replacingOccurrences(of: ".md", with: "")

        // Read file content
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

        // Extract title from first markdown heading
        let title: String
        if let firstLine = content.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: true)
            .first(where: { $0.hasPrefix("# ") }) {
            title = String(firstLine.dropFirst(2))
        } else {
            title = slug
        }

        // Snippet: first 500 chars of content (skip frontmatter/heading)
        let snippet = String(content.prefix(500))

        results.append(WikiPageResult(slug: slug, title: title, snippet: snippet, path: path))
    }

    return results
}
