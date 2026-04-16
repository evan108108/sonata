import Foundation
import Hummingbird
import GRDB
#if canImport(Accelerate)
import Accelerate
#endif

// Use CommonCrypto via bridging
#if canImport(CommonCrypto)
import CommonCrypto
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
