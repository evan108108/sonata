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

private let validRelationTypes: Set<String> = ["memory", "entity"]

// MARK: - Route Registration

/// Register all /api/relation routes on `router`.
public func registerRelationRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/relation")

    // POST /api/relation — create a relation (deduplicates)
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: CreateRelationRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.sourceId.isEmpty else {
            return errorResponse("sourceId is required")
        }
        guard validRelationTypes.contains(body.sourceType) else {
            return errorResponse("sourceType must be 'memory' or 'entity'")
        }
        guard !body.targetId.isEmpty else {
            return errorResponse("targetId is required")
        }
        guard validRelationTypes.contains(body.targetType) else {
            return errorResponse("targetType must be 'memory' or 'entity'")
        }
        guard !body.relation.isEmpty else {
            return errorResponse("relation is required")
        }

        let now = nowMs()

        do {
            let resultId = try await dbPool.write { db -> String in
                // Check for existing duplicate
                let existing = try RelationRow.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM relations
                    WHERE sourceId = ? AND sourceType = ? AND targetId = ? AND relation = ?
                    """,
                    arguments: [body.sourceId, body.sourceType, body.targetId, body.relation]
                )

                if let existing = existing {
                    return existing.id
                }

                let id = newUUID()
                try db.execute(
                    sql: """
                    INSERT INTO relations (id, sourceId, sourceType, targetId, targetType, relation, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [id, body.sourceId, body.sourceType, body.targetId, body.targetType, body.relation, now]
                )
                return id
            }
            return jsonResponse(StoreResponse(id: resultId), status: .ok)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/relation/list — list relations
    api.get("/list") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let limit = Int(queryParams["limit"] ?? "") ?? 200

        do {
            let rows = try await dbPool.read { db in
                try RelationRow.fetchAll(
                    db,
                    sql: "SELECT * FROM relations ORDER BY createdAt DESC LIMIT ?",
                    arguments: [limit]
                )
            }
            return jsonResponse(rows.map(relationRowToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // DELETE /api/relation?id= — delete a relation
    api.delete("/") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM relations WHERE id = ?", arguments: [id])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }
}
