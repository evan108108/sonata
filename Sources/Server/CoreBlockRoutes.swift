import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct CoreBlockRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "coreBlocks"

    var id: String
    var key: String
    var category: String
    var content: String
    var priority: Int
    var updatedAt: Int64
    var active: Bool
    var compressed: String?

    enum CodingKeys: String, CodingKey {
        case id, key, category, content, priority, updatedAt, active, compressed
    }
}

// MARK: - Request Bodies

struct UpsertCoreBlockRequest: Decodable {
    let key: String
    let category: String
    let content: String
    let priority: Int?
    let compressed: String?
}

// MARK: - Response

struct CoreBlockResponse: Encodable {
    let _id: String
    let key: String
    let category: String
    let content: String
    let priority: Int
    let updatedAt: Int64
    let active: Bool
    let compressed: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(key, forKey: .key)
        try c.encode(category, forKey: .category)
        try c.encode(content, forKey: .content)
        try c.encode(priority, forKey: .priority)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(active, forKey: .active)
        try c.encodeIfPresent(compressed, forKey: .compressed)
    }

    enum CodingKeys: String, CodingKey {
        case _id, key, category, content, priority, updatedAt, active, compressed
    }
}
