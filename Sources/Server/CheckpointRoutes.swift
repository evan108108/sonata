import Foundation
import Hummingbird
import GRDB

// MARK: - Database Rows

struct CheckpointRow: FetchableRecord, Codable {
    static let databaseTableName = "checkpoints"
    var id: String
    var state: String
    var skills: String?
    var project: String?
    var createdAt: Int64
}

struct HandoffRow: FetchableRecord, Codable {
    static let databaseTableName = "handoffs"
    var id: String
    var content: String
    var createdAt: Int64
}

// MARK: - Request / Response

struct SaveCheckpointRequest: Decodable {
    let state: String
    let skills: String?
    let project: String?
}

struct CheckpointResponse: Encodable {
    let id: String
    let state: String
    let skills: String?
    let project: String?
    let createdAt: Int64
}

struct SaveHandoffRequest: Decodable {
    let content: String
}

struct HandoffResponse: Encodable {
    let id: String
    let content: String
    let createdAt: Int64
}
