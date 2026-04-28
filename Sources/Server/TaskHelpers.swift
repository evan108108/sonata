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
            arr = arr.flatMap { s -> [String] in
                let t = s.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("["),
                   let d = t.data(using: .utf8),
                   let inner = try? JSONDecoder().decode([String].self, from: d) {
                    return inner
                }
                return [s]
            }
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

/// Roll a subtask's status change up to its parent (and grandparents, etc.).
///
/// - If any sibling is `active`, the parent (if still `pending`) is promoted to `active`.
/// - If all siblings are terminal, the parent is set to the aggregate result:
///   all-cancelled → `cancelled`; any failure → `failed`; otherwise → `completed`.
///   The rolled-up `result` column gets a one-line summary.
/// - Recurses so a deeply nested hierarchy settles in one write.
/// - No-op when `childTaskId` has no parent, or when the parent has no children.
///
/// Must be called inside an existing GRDB write transaction.
func rollUpParentStatus(childTaskId: String, in db: Database, now: Int64) throws {
    guard let parentId = try String.fetchOne(db, sql: """
        SELECT parentTask FROM tasks WHERE id = ?
    """, arguments: [childTaskId]),
    !parentId.isEmpty else { return }

    let rows = try Row.fetchAll(db, sql: """
        SELECT status FROM tasks WHERE parentTask = ?
    """, arguments: [parentId])
    let statuses = rows.compactMap { $0["status"] as? String }
    guard !statuses.isEmpty else { return }

    let terminalStatuses: Set<String> = ["completed", "failed", "cancelled"]
    let allTerminal = statuses.allSatisfy { terminalStatuses.contains($0) }
    guard allTerminal else {
        // Not all terminal — promote parent from pending to active if any child is active.
        if statuses.contains("active") {
            try db.execute(sql: """
                UPDATE tasks SET status = 'active', updatedAt = ?
                WHERE id = ? AND status = 'pending'
            """, arguments: [now, parentId])
        }
        return
    }

    let hasFailure = statuses.contains("failed")
    let allCancelled = statuses.allSatisfy { $0 == "cancelled" }
    let parentStatus = allCancelled ? "cancelled" : (hasFailure ? "failed" : "completed")

    let completed = statuses.filter { $0 == "completed" }.count
    let failed = statuses.filter { $0 == "failed" }.count
    let cancelled = statuses.filter { $0 == "cancelled" }.count
    let summary = "\(completed)/\(statuses.count) completed, \(failed) failed, \(cancelled) cancelled"

    try db.execute(sql: """
        UPDATE tasks
        SET status = ?, result = ?, completedAt = ?, updatedAt = ?
        WHERE id = ?
    """, arguments: [parentStatus, summary, now, now, parentId])

    // Recurse for nested parents (grandparent rollup).
    try rollUpParentStatus(childTaskId: parentId, in: db, now: now)
}
