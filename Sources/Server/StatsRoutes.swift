import Foundation
import Hummingbird
import GRDB

// MARK: - Response Types

struct StatsResponse: Encodable {
    let totalMemories: Int
    let avgImportance: Double
    let byType: [String: Int]
    let entityCount: Int
    let relationCount: Int
}

// MARK: - Route Registration

public func registerStatsRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    // GET /api/stats
    router.get("/api/stats") { _, _ -> Response in
        do {
            let stats = try await dbPool.read { db -> StatsResponse in
                // Total memories + average importance
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS cnt, COALESCE(AVG(importance), 0) AS avg_imp
                    FROM memories
                """)!
                let totalMemories: Int = row["cnt"]
                let avgImportance: Double = row["avg_imp"]

                // By type
                let typeRows = try Row.fetchAll(db, sql: """
                    SELECT type, COUNT(*) AS cnt FROM memories GROUP BY type
                """)
                var byType: [String: Int] = [:]
                for r in typeRows {
                    let typeName: String = r["type"]
                    let count: Int = r["cnt"]
                    byType[typeName] = count
                }

                // Entity count
                let entityRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM entities")!
                let entityCount: Int = entityRow["cnt"]

                // Relation count
                let relationRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM relations")!
                let relationCount: Int = relationRow["cnt"]

                return StatsResponse(
                    totalMemories: totalMemories,
                    avgImportance: avgImportance,
                    byType: byType,
                    entityCount: entityCount,
                    relationCount: relationCount
                )
            }

            return jsonResponse(stats)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
