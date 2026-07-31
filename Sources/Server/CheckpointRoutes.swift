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
    /// Added by v31; decoded here (EFB-48) so a restore can report *whose*
    /// checkpoint it returned. Without it a caller had no way to tell an
    /// inherited checkpoint from its own.
    var sessionId: String?
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
    /// Owning session, when the checkpoint was saved with one. Lets a caller
    /// machine-check that a restore returned its own state instead of relying
    /// on reading the prose to notice.
    let sessionId: String?
}

struct SaveHandoffRequest: Decodable {
    let content: String
}

struct HandoffResponse: Encodable {
    let id: String
    let content: String
    let createdAt: Int64
}
