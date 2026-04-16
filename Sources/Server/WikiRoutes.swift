import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct WikiPageRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "wikiPages"

    var id: String
    var slug: String
    var title: String
    var namespace: String?
    var pageType: String?
    var parentSlug: String?
    var topic: String?
    var lastCompiled: Int64
    var memoryCount: Int
    var dirty: Bool
    var documentId: String?
    var filePath: String
    var abstract: String?
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, slug, title, namespace, pageType, parentSlug, topic
        case lastCompiled, memoryCount, dirty, documentId, filePath, abstract
        case createdAt, updatedAt
    }
}

// MARK: - Request Bodies

struct UpsertWikiPageRequest: Decodable {
    let slug: String
    let title: String
    let namespace: String?
    let pageType: String?
    let parentSlug: String?
    let topic: String?
    let memoryCount: Int?
    let documentId: String?
    let filePath: String
    let abstract: String?
}

struct PatchWikiPageRequest: Decodable {
    let slug: String
    let title: String?
    let namespace: String?
    let pageType: String?
    let parentSlug: String?
    let topic: String?
    let lastCompiled: Int64?
    let memoryCount: Int?
    let dirty: Bool?
    let documentId: String?
    let filePath: String?
    let abstract: String?
}

// MARK: - Response Types

struct WikiPageResponse: Encodable {
    let _id: String
    let slug: String
    let title: String
    let namespace: String?
    let pageType: String?
    let parentSlug: String?
    let topic: String?
    let lastCompiled: Int64
    let memoryCount: Int
    let dirty: Bool
    let documentId: String?
    let filePath: String
    let abstract: String?
    let content: String?
    let createdAt: Int64
    let updatedAt: Int64
}
