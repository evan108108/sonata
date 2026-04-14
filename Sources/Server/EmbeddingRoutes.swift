import Foundation
import Hummingbird
import GRDB
#if canImport(Accelerate)
import Accelerate
#endif

// MARK: - Request / Response Types

struct StoreWithEmbeddingRequest: Decodable {
    let content: String
    let type: String
    let tags: [String]?
    let source: String?
    let importance: Double?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
    let createdAt: Int64?
}

struct VectorSearchResult: Encodable {
    let _id: String
    let score: Double
}

private let validMemoryTypesEmb: Set<String> = [
    "learning", "observation", "decision", "preference",
    "error_pattern", "code_pattern", "conversation_summary",
    "reflection", "feeling", "fact"
]

// MARK: - OpenRouter Embedding Client

struct OpenRouterEmbeddingRequest: Encodable {
    let model: String
    let input: String
}

struct OpenRouterEmbeddingResponse: Decodable {
    struct DataItem: Decodable {
        let embedding: [Float]
    }
    let data: [DataItem]
}

/// Call OpenRouter embeddings API. Returns float32 array.
func generateEmbedding(text: String, apiKey: String) async throws -> [Float] {
    let url = URL(string: "https://openrouter.ai/api/v1/embeddings")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let body = OpenRouterEmbeddingRequest(model: "openai/text-embedding-3-small", input: text)
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        throw EmbeddingError.apiError(statusCode: statusCode, body: bodyStr)
    }

    let decoded = try JSONDecoder().decode(OpenRouterEmbeddingResponse.self, from: data)
    guard let first = decoded.data.first else {
        throw EmbeddingError.noData
    }
    return first.embedding
}

enum EmbeddingError: Error, LocalizedError {
    case apiError(statusCode: Int, body: String)
    case noData
    case missingApiKey

    var errorDescription: String? {
        switch self {
        case .apiError(let code, let body): return "OpenRouter API error \(code): \(body)"
        case .noData: return "No embedding data in response"
        case .missingApiKey: return "OPENROUTER_API_KEY environment variable not set"
        }
    }
}

/// Pack [Float] into Data (little-endian float32 BLOB)
private func packFloats(_ floats: [Float]) -> Data {
    floats.withUnsafeBufferPointer { buf in
        Data(buffer: buf)
    }
}

/// Unpack Data back into [Float]
func unpackFloats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { raw in
        let buf = raw.bindMemory(to: Float.self)
        return Array(buf)
    }
}

/// Cosine similarity using Accelerate vDSP
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    let n = vDSP_Length(a.count)
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, n)
    vDSP_dotpr(a, 1, a, 1, &normA, n)
    vDSP_dotpr(b, 1, b, 1, &normB, n)
    let denom = sqrtf(normA) * sqrtf(normB)
    guard denom > 0 else { return 0 }
    return dot / denom
}

// SHA256 content hash for dedup
private func sha256Hex(_ string: String) -> String {
    let data = Data(string.utf8)
    var hash = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { buf in
        _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}

// Use CommonCrypto via bridging
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - Route Registration

public func registerEmbeddingRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/memory")

    // POST /api/memory/store-with-embedding
    api.post("/store-with-embedding") { request, context -> Response in
        guard let apiKey = SecretStore.get("OPENROUTER_API_KEY"), !apiKey.isEmpty else {
            return errorResponse("OPENROUTER_API_KEY not set", status: .internalServerError)
        }

        guard let body = try? await request.decode(as: StoreWithEmbeddingRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard validMemoryTypesEmb.contains(body.type) else {
            return errorResponse("Invalid memory type '\(body.type)'")
        }

        // Generate embedding
        let embedding: [Float]
        do {
            embedding = try await generateEmbedding(text: body.content, apiKey: apiKey)
        } catch {
            return errorResponse("Embedding generation failed: \(error.localizedDescription)", status: .internalServerError)
        }

        let now = nowMs()
        let createdAt = body.createdAt ?? now
        let memoryId = newUUID()
        let embeddingId = newUUID()
        let tagsJSON = encodeTags(body.tags ?? [])
        let embeddingBlob = packFloats(embedding)
        let contentHash = sha256Hex(body.content)

        do {
            try await dbPool.write { db in
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
                        memoryId, body.content, body.type, tagsJSON,
                        body.source, body.importance ?? 5.0,
                        body.validFrom ?? createdAt, body.validUntil,
                        body.project, body.topic,
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
                        "openai/text-embedding-3-small", embedding.count,
                        contentHash, createdAt
                    ]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(StoreResponse(id: memoryId), status: .created)
    }

    // GET /api/memory/vector-search?q=...&limit=...
    api.get("/vector-search") { request, _ -> Response in
        guard let apiKey = SecretStore.get("OPENROUTER_API_KEY"), !apiKey.isEmpty else {
            return errorResponse("OPENROUTER_API_KEY not set", status: .internalServerError)
        }

        let queryParams = request.uri.queryParameters
        guard let q = queryParams["q"].map(String.init), !q.isEmpty else {
            return errorResponse("Missing required query parameter 'q'")
        }
        let limit = Int(queryParams["limit"] ?? "") ?? 10

        // Generate query embedding
        let queryEmbedding: [Float]
        do {
            queryEmbedding = try await generateEmbedding(text: q, apiKey: apiKey)
        } catch {
            return errorResponse("Embedding generation failed: \(error.localizedDescription)", status: .internalServerError)
        }

        // Brute-force scan all embeddings
        do {
            let rows = try await dbPool.read { db -> [(String, Data)] in
                try Row.fetchAll(db, sql: "SELECT memoryId, embedding FROM memoryEmbeddings")
                    .map { row in
                        (row["memoryId"] as String, row["embedding"] as Data)
                    }
            }

            var scored: [(String, Double)] = []
            for (memoryId, blob) in rows {
                let emb = unpackFloats(blob)
                let sim = cosineSimilarity(queryEmbedding, emb)
                scored.append((memoryId, Double(sim)))
            }

            scored.sort { $0.1 > $1.1 }
            let topN = scored.prefix(limit)
            let results = topN.map { VectorSearchResult(_id: $0.0, score: $0.1) }

            return jsonResponse(results)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
