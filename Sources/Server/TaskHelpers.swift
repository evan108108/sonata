import Foundation
import GRDB

/// Shared helper: remove `taskId` from the `blockedBy` JSON arrays of all
/// pending tasks that reference it. Must be called inside an existing GRDB
/// write transaction (takes `Database`, not `DatabasePool`).
func unblockDependents(taskId: String, in db: Database, now: Int64) throws {
    let dependents = try Row.fetchAll(db, sql: """
        SELECT id, blockedBy FROM tasks WHERE status = 'pending' AND blockedBy LIKE ?
    """, arguments: ["%\(taskId)%"])

    for row in dependents {
        let depId = row["id"] as! String
        let blockedByJSON = row["blockedBy"] as? String ?? "[]"
        if let data = blockedByJSON.data(using: .utf8),
           var arr = try? JSONDecoder().decode([String].self, from: data) {
            arr.removeAll { $0 == taskId }
            if let newJSON = try? JSONEncoder().encode(arr),
               let newStr = String(data: newJSON, encoding: .utf8) {
                try db.execute(
                    sql: "UPDATE tasks SET blockedBy = ?, updatedAt = ? WHERE id = ?",
                    arguments: [newStr, now, depId]
                )
            }
        }
    }
}
