import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definition for /api/stats route.
// Handler logic is duplicated from StatsRoutes.swift so the two implementations
// run side-by-side. When the old routes are retired these become canonical.

let statsActions: [SonataAction] = [

    // GET /api/stats
    SonataAction(
        name: "mem_stats",
        description: "Aggregate memory stats: totals, average importance, counts by type, entity and relation counts.",
        group: "/api",
        path: "/stats",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let stats = try await ctx.dbPool.read { db -> StatsResponse in
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
                return stats
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
