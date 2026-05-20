import Foundation
import GRDB

// Restart-recovery v0 (sonata-restart-recovery-v0-plan.md, T1).
//
// At app boot, find workers that died holding active work so a replacement
// process can be spawned with the same workerId/sessionId/sessionLabel and
// claude can resume the prior conversation context. T4 wires this into
// WorkerManager.respawnRecoveryWorkers(); this file only owns the query.

struct RecoveryCandidate {
    let workerId: String
    let sessionId: String
    let sessionLabel: String
    let currentEventId: String
    let taskId: String
}

/// Return workers whose lastHeartbeat is older than `cutoffMs` AND whose
/// `currentEventId` points to a still-active task started after `taskMaxAgeMs`.
/// Both arguments are absolute epoch-ms thresholds bound straight into the SQL:
///   `lastHeartbeat < cutoffMs` (worker stale) and
///   `tasks.startedAt > taskMaxAgeMs` (task not hopelessly stale).
///
/// Schema-migration safety (plan §6): on any query failure we log and return
/// an empty array. The default boot path then proceeds without recovered
/// workers, and `recoverOrphans()` resets stranded active tasks to `pending`
/// on the dispatcher's first tick.
func findStaleWorkersWithActiveWork(
    in dbPool: DatabasePool,
    cutoffMs: Int64,
    taskMaxAgeMs: Int64
) -> [RecoveryCandidate] {
    do {
        return try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT w.workerId AS worker_id,
                       w.sessionId AS session_id,
                       w.sessionLabel AS session_label,
                       w.currentEventId AS current_event_id,
                       json_extract(we.payload, '$.task_id') AS task_id
                FROM workers w
                JOIN workerEvents we ON we.id = w.currentEventId
                JOIN tasks t ON t.id = json_extract(we.payload, '$.task_id')
                WHERE w.lastHeartbeat < ?
                  AND w.currentEventId IS NOT NULL
                  AND w.currentEventId != ''
                  AND t.status = 'active'
                  AND t.startedAt > ?
            """, arguments: [cutoffMs, taskMaxAgeMs])

            return rows.compactMap { row -> RecoveryCandidate? in
                guard let workerId = row["worker_id"] as? String,
                      let sessionId = row["session_id"] as? String,
                      let currentEventId = row["current_event_id"] as? String,
                      let taskId = row["task_id"] as? String
                else { return nil }
                let sessionLabel = row["session_label"] as? String ?? ""
                return RecoveryCandidate(
                    workerId: workerId,
                    sessionId: sessionId,
                    sessionLabel: sessionLabel,
                    currentEventId: currentEventId,
                    taskId: taskId
                )
            }
        }
    } catch {
        print("[restart-recovery] findStaleWorkersWithActiveWork failed: \(error.localizedDescription)")
        return []
    }
}
