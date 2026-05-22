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

/// Which embedding backend to use. Default = OpenRouter (unchanged behavior).
/// Set UserDefaults "sonata.embeddingProvider" = "local" (or env
/// SONATA_EMBEDDING_PROVIDER=local) to use the local nomic-embed-text-v1.5
/// served by llama-server (EmbeddingServerManager).
enum EmbeddingProvider: String {
    case openRouter
    case local

    static var current: EmbeddingProvider {
        let raw = UserDefaults.standard.string(forKey: "sonata.embeddingProvider")
            ?? ProcessInfo.processInfo.environment["SONATA_EMBEDDING_PROVIDER"]
        return raw == "local" ? .local : .openRouter
    }

    /// Model identifier persisted alongside stored embeddings, so a later
    /// re-embed/migration can tell which vectors came from which model.
    var modelId: String {
        switch self {
        case .openRouter: return "openai/text-embedding-3-small"
        case .local:      return "nomic-embed-text-v1.5"
        }
    }
}

/// Pluggable embedding entrypoint. Routes to the local llama-server or OpenRouter
/// per `EmbeddingProvider.current`. `isQuery` selects nomic's task prefix
/// (search_query vs search_document); OpenRouter ignores it. Throws
/// `EmbeddingError.missingApiKey` when OpenRouter is selected without a key.
func embedText(_ text: String, isQuery: Bool) async throws -> [Float] {
    switch EmbeddingProvider.current {
    case .local:
        return try await EmbeddingServerManager.shared.embed(text, isQuery: isQuery)
    case .openRouter:
        guard let apiKey = SecretStore.get("OPENROUTER_API_KEY"), !apiKey.isEmpty else {
            throw EmbeddingError.missingApiKey
        }
        return try await generateEmbedding(text: text, apiKey: apiKey)
    }
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
