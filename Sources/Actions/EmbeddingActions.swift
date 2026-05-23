import Foundation
import GRDB
import Hummingbird
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// Phase 2 migration: action definitions for embedding routes.
// Handler logic duplicated from EmbeddingRoutes.swift.

private let validMemoryTypesForEmbeddingAction: Set<String> = [
    "learning", "observation", "decision", "preference",
    "error_pattern", "code_pattern", "conversation_summary",
    "reflection", "feeling", "fact"
]

/// Pack [Float] into Data (little-endian float32 BLOB)
private func packFloatsForAction(_ floats: [Float]) -> Data {
    floats.withUnsafeBufferPointer { buf in
        Data(buffer: buf)
    }
}

// SHA256 content hash for dedup
private func sha256HexForAction(_ string: String) -> String {
    let data = Data(string.utf8)
    var hash = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { buf in
        _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}

let embeddingActions: [SonataAction] = [

    // POST /api/memory/store-with-embedding
    SonataAction(
        name: "embedding_store",
        description: "Store a memory and generate an embedding blob for it.",
        group: "/api/memory",
        path: "/store-with-embedding",
        method: .post,
        params: [
            ActionParam("content", .string, required: true, description: "Memory content"),
            ActionParam("type", .string, required: true, description: "Memory type"),
            ActionParam("tags", .stringArray, description: "Tags (comma-separated or array)"),
            ActionParam("source", .string, description: "Source project/context"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("topic", .string, description: "Topic namespace"),
            ActionParam("importance", .number, description: "1-10 importance rating"),
            ActionParam("validFrom", .integer, description: "Validity window start (epoch ms)"),
            ActionParam("validUntil", .integer, description: "Validity window end (epoch ms)"),
            ActionParam("createdAt", .integer, description: "Override createdAt (epoch ms)"),
        ],
        handler: { ctx in
            let content = try ctx.params.require("content")
            let type = try ctx.params.require("type")
            guard validMemoryTypesForEmbeddingAction.contains(type) else {
                throw ActionError.invalidParam("type", "Invalid memory type '\(type)'")
            }

            // Generate embedding (local nomic or OpenRouter per EmbeddingProvider.current)
            let embedding: [Float]
            do {
                embedding = try await embedText(content, isQuery: false)
            } catch {
                throw ActionError.custom("Embedding generation failed: \(error.localizedDescription)", .internalServerError)
            }

            let now = nowMs()
            let createdAt = ctx.params.int("createdAt").map { Int64($0) } ?? now
            let memoryId = newUUID()
            let embeddingId = newUUID()
            let tagsJSON = encodeTags(ctx.params.stringArray("tags") ?? [])
            let source = ctx.params.string("source")
            let importance = ctx.params.double("importance") ?? 5.0
            let validFrom = ctx.params.int("validFrom").map { Int64($0) } ?? createdAt
            let validUntil = ctx.params.int("validUntil").map { Int64($0) }
            let project = ctx.params.string("project")
            let topic = ctx.params.string("topic")
            let embeddingBlob = packFloatsForAction(embedding)
            let contentHash = sha256HexForAction(content)

            do {
                try await ctx.dbPool.write { db in
                    // Insert memory
                    try db.execute(
                        sql: """
                        INSERT INTO memories
                            (id, content, type, tags, source, importance,
                             validFrom, validUntil, project, topic,
                             createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            memoryId, content, type, tagsJSON,
                            source, importance,
                            validFrom, validUntil,
                            project, topic,
                            createdAt, createdAt
                        ]
                    )
                    // Insert embedding
                    try db.execute(
                        sql: """
                        INSERT INTO memoryEmbeddings
                            (id, memoryId, embedding, model, dimensions, contentHash, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            embeddingId, memoryId, embeddingBlob,
                            EmbeddingProvider.current.modelId, embedding.count,
                            contentHash, createdAt
                        ]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            return StoreResponse(id: memoryId)
        }
    ),

    // GET /api/memory/vector-search
    SonataAction(
        name: "embedding_vector_search",
        description: "Brute-force cosine similarity vector search over memory embeddings.",
        group: "/api/memory",
        path: "/vector-search",
        method: .get,
        params: [
            ActionParam("q", .string, required: true, description: "Query string"),
            ActionParam("limit", .integer, description: "Max results (default 10)"),
        ],
        handler: { ctx in
            let q = try ctx.params.require("q")
            let limit = ctx.params.int("limit") ?? 10

            // Generate query embedding (local nomic or OpenRouter per EmbeddingProvider.current)
            let queryEmbedding: [Float]
            do {
                queryEmbedding = try await embedText(q, isQuery: true)
            } catch {
                throw ActionError.custom("Embedding generation failed: \(error.localizedDescription)", .internalServerError)
            }

            // Brute-force scan all embeddings
            do {
                let rows = try await ctx.dbPool.read { db -> [(String, Data)] in
                    try Row.fetchAll(db, sql: "SELECT memoryId, embedding FROM memoryEmbeddings")
                        .map { row in
                            (row["memoryId"] as String, row["embedding"] as Data)
                        }
                }

                // Mean-center for anisotropic local embeddings (nomic); no-op for OpenRouter.
                let corpus = rows.map { ($0.0, unpackFloats($0.1)) }
                let doCenter = embeddingNeedsCentering
                let mu = doCenter ? corpusMean(corpus.map { $0.1 }) : []
                let q = doCenter ? centeredVector(queryEmbedding, by: mu) : queryEmbedding
                var scored: [(String, Double)] = []
                for (memoryId, emb) in corpus {
                    let v = doCenter ? centeredVector(emb, by: mu) : emb
                    scored.append((memoryId, Double(cosineSimilarity(q, v))))
                }

                scored.sort { $0.1 > $1.1 }
                let topN = scored.prefix(limit)
                return topN.map { VectorSearchResult(_id: $0.0, score: $0.1) }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
