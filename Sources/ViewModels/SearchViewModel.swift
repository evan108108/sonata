import Foundation
import SwiftUI

// MARK: - Wire types (mirror /api/recall response)

struct RecallMemoryDTO: Decodable, Identifiable, Hashable {
    let _id: String
    let content: String?
    let type: String
    let l0: String?
    let l1: String?
    let source: String?
    let createdAt: Int64
    let importance: Double?
    let tags: [String]?
    let _rankScore: Double?

    var id: String { _id }
}

struct RecallEntityDTO: Decodable, Identifiable, Hashable {
    let _id: String
    let name: String
    let type: String
    let description: String?

    var id: String { _id }
}

struct RecallWikiPageDTO: Decodable, Identifiable, Hashable {
    let slug: String
    let title: String
    let snippet: String
    let path: String?

    var id: String { slug }
}

struct RecallTokenUsageDTO: Decodable {
    let truncated: Bool?
    let used: Int?
    let budget: Int?
}

struct RecallResponseDTO: Decodable {
    let memories: [RecallMemoryDTO]?
    let entities: [RecallEntityDTO]?
    let wikiPages: [RecallWikiPageDTO]?
    let tokenUsage: RecallTokenUsageDTO?
}

// MARK: - View model

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var lastSubmittedQuery: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var isShowingResults: Bool = false
    @Published var memories: [RecallMemoryDTO] = []
    @Published var entities: [RecallEntityDTO] = []
    @Published var wikiPages: [RecallWikiPageDTO] = []
    @Published var truncated: Bool = false

    static let maxQueryLength = 500

    private var requestSeq: Int = 0

    func clamp() {
        if query.count > Self.maxQueryLength {
            query = String(query.prefix(Self.maxQueryLength))
        }
    }

    func dismiss() {
        isShowingResults = false
    }

    func clear() {
        query = ""
        lastSubmittedQuery = ""
        memories = []
        entities = []
        wikiPages = []
        errorMessage = nil
        truncated = false
        isShowingResults = false
    }

    func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bounded = String(trimmed.prefix(Self.maxQueryLength))

        requestSeq &+= 1
        let mySeq = requestSeq
        lastSubmittedQuery = bounded
        isShowingResults = true
        isLoading = true
        errorMessage = nil

        Task { [weak self] in
            await self?.fetch(topic: bounded, seq: mySeq)
        }
    }

    private func fetch(topic: String, seq: Int) async {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = sonataPort
        components.path = "/api/recall"
        components.queryItems = [
            URLQueryItem(name: "topic", value: topic),
            URLQueryItem(name: "limit", value: "10"),
        ]

        guard let url = components.url else {
            applyIfCurrent(seq: seq) {
                self.errorMessage = "Couldn't build search URL."
                self.isLoading = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                applyIfCurrent(seq: seq) {
                    self.errorMessage = "Sona search failed (\(http.statusCode)). Try again."
                    self.memories = []
                    self.entities = []
                    self.wikiPages = []
                    self.truncated = false
                    self.isLoading = false
                }
                return
            }

            let decoder = JSONDecoder()
            let decoded = try decoder.decode(RecallResponseDTO.self, from: data)
            applyIfCurrent(seq: seq) {
                self.memories = decoded.memories ?? []
                self.entities = decoded.entities ?? []
                self.wikiPages = decoded.wikiPages ?? []
                self.truncated = decoded.tokenUsage?.truncated ?? false
                self.errorMessage = nil
                self.isLoading = false
            }
        } catch {
            applyIfCurrent(seq: seq) {
                self.errorMessage = "Sona server unreachable."
                self.memories = []
                self.entities = []
                self.wikiPages = []
                self.truncated = false
                self.isLoading = false
            }
        }
    }

    private func applyIfCurrent(seq: Int, _ block: () -> Void) {
        guard seq == requestSeq else { return }
        block()
    }
}

// MARK: - Cross-view navigation

extension Notification.Name {
    static let sonataOpenWikiSlug = Notification.Name("sonataOpenWikiSlug")
}
