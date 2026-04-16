import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct RelationRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "relations"

    var id: String
    var sourceId: String
    var sourceType: String
    var targetId: String
    var targetType: String
    var relation: String
    var createdAt: Int64
}

// MARK: - Request Bodies

struct CreateRelationRequest: Decodable {
    let sourceId: String
    let sourceType: String
    let targetId: String
    let targetType: String
    let relation: String
}

// MARK: - Response shapes

struct RelationResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let sourceId: String
    let sourceType: String
    let targetId: String
    let targetType: String
    let relation: String
    let createdAt: Int64
}

// MARK: - Helpers

func relationRowToResponse(_ row: RelationRow) -> RelationResponse {
    RelationResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        sourceId: row.sourceId,
        sourceType: row.sourceType,
        targetId: row.targetId,
        targetType: row.targetType,
        relation: row.relation,
        createdAt: row.createdAt
    )
}
