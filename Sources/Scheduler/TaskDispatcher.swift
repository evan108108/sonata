import Foundation
import GRDB
import Logging

/// Polls for actionable tasks and dispatches them to bridge-attached workers.
///
/// Dispatch: push the task to an idle worker via the channel (SonataChannelServer).
/// Workers running Claude Code with `--dangerously-load-development-channels server:sonata-channel`
/// pick it up through the MCP channel protocol. If channel dispatch fails (no idle worker
/// claimed the event in time), the task stays `pending` and the next poll cycle retries
/// once a worker frees up. Bridge-only: no headless `claude -p` fallback.
actor TaskDispatcher {
    private let dbPool: DatabasePool
    private let logger: Logger
    private let channelServer: SonataChannelServer
    private var isRunning = false
    private var activeTasks: Set<String> = []  // task IDs currently being executed

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        self.channelServer = SonataChannelServer(dbPool: dbPool)
        var logger = Logger(label: "sonata.dispatcher")
        logger.logLevel = .info
        self.logger = logger
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("TaskDispatcher started (polling every 10s, dynamic concurrency)")
        Task {
            await recoverOrphans()
            await pollLoop()
        }
    }

    func stop() {
        isRunning = false
    }

    private func pollLoop() async {
        while isRunning {
            do {
                try await poll()
            } catch {
                logger.error("Dispatcher poll error: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
        }
    }

    /// How long a scheduled (cron) task stays dispatchable after it was created.
    ///
    /// A cron run is only meaningful near its scheduled moment: its prompt carries a
    /// work manifest snapshotted at fire time, so executing it hours later re-runs
    /// stale work — and can clobber a peer's fresh output. Recurring jobs are
    /// self-healing (the next firing does the work with a current manifest), so
    /// dropping a late run is strictly better than running it against a moved world.
    private static let scheduledTaskMaxStalenessMs: Int64 = 2 * 60 * 60 * 1000  // 2 hours

    /// Retire scheduled tasks that sat undispatched past their useful life.
    ///
    /// The backend can be up with zero attached workers — `poll()` then returns early
    /// on every cycle and pending tasks accumulate silently. Coalescing in
    /// DefaultClaudeRunner keeps only the newest run per job, and this keeps even that
    /// one from executing long after the fact.
    private func expireStaleScheduledTasks() async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoff = now - Self.scheduledTaskMaxStalenessMs
        do {
            try await dbPool.write { [logger] db in
                let stale = try Row.fetchAll(db, sql: """
                    SELECT id, title, createdAt FROM tasks
                    WHERE status = 'pending' AND source = 'scheduler' AND createdAt < ?
                """, arguments: [cutoff])

                for row in stale {
                    let taskId = row["id"] as! String
                    let title = row["title"] as? String ?? taskId
                    let ageMin = ((now - (row["createdAt"] as? Int64 ?? now)) / 60_000)
                    try db.execute(sql: """
                        UPDATE tasks SET status = 'cancelled', lastError = ?, updatedAt = ?
                        WHERE id = ?
                    """, arguments: ["expired: undispatched for \(ageMin)m, past the scheduled-task staleness window", now, taskId])
                    logger.warning("Expired stale scheduled task \"\(title.prefix(60))\" (\(taskId)) — \(ageMin)m old, never dispatched")
                }
                if !stale.isEmpty {
                    logger.warning("Expired \(stale.count) stale scheduled task(s) — a cron run that missed its window is dropped, not run late")
                }
            }
        } catch {
            logger.error("Stale scheduled-task expiry failed: \(error.localizedDescription)")
        }
    }

    private func poll() async throws {
        // Drop cron runs that missed their window BEFORE looking for workers — this
        // must run even when no worker is idle, since that is exactly the condition
        // that lets the backlog build.
        await expireStaleScheduledTasks()

        // Dynamic concurrency: match available idle workers. Counts pool slots
        // only (`poolSlotSQLPredicate`) — a non-pool session holding a
        // `workers` row, such as a sidecar, would otherwise inflate the count
        // and let the dispatcher release one more task than the pool can take.
        let idleWorkerCount: Int = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM workers
                WHERE status = 'idle' AND lastHeartbeat >= ?
                  AND \(poolSlotSQLPredicate)
            """, arguments: [Int64(Date().timeIntervalSince1970 * 1000) - 30_000]) ?? 0
        }) ?? 0

        guard idleWorkerCount > 0 else { return }
        let slotsAvailable = idleWorkerCount  // one task per idle worker

        // Find actionable tasks: pending, assigned to scheduler, not blocked,
        // and leaf-only (parent/container tasks with subtasks are skipped —
        // they have no prompt and would waste worker turns).
        let tasks = try await dbPool.read { db -> [DispatcherTaskRow] in
            try DispatcherTaskRow.fetchAll(db, sql: """
                SELECT * FROM tasks t
                WHERE t.status = 'pending'
                AND (t.assignedTo = 'scheduler' OR t.assignedTo IS NULL OR t.assignedTo = '')
                AND (t.blockedBy IS NULL OR t.blockedBy = '[]' OR t.blockedBy = '')
                AND NOT EXISTS (SELECT 1 FROM tasks c WHERE c.parentTask = t.id)
                ORDER BY
                    CASE t.priority
                        WHEN 'critical' THEN 0
                        WHEN 'high' THEN 1
                        WHEN 'normal' THEN 2
                        WHEN 'low' THEN 3
                        WHEN 'backlog' THEN 4
                    END,
                    t.createdAt ASC
                LIMIT ?
            """, arguments: [slotsAvailable])
        }

        // One cycle id per poll tick, shared by every task dispatched in this
        // pass. See dispatchToChannel: same tick → same cycle → the idempotency
        // UNIQUE index still catches a genuine double-dispatch; next tick → new
        // cycle → a task that came back to `pending` is retried 10s later
        // instead of being locked out until midnight.
        let dispatchCycle = String(Int64(Date().timeIntervalSince1970 * 1000))

        for task in tasks {
            guard !activeTasks.contains(task.id) else { continue }
            await dispatch(task, dispatchCycle: dispatchCycle)
        }
    }

    private func dispatch(_ task: DispatcherTaskRow, dispatchCycle: String) async {
        let taskId = task.id
        let title = task.title
        let prompt = task.prompt ?? task.title

        logger.info("Dispatching: \"\(title)\" (\(taskId))")

        // Strategy 1: Try channel dispatch to an idle TUI worker
        if let eventId = await channelServer.dispatchToChannel(
            taskId: taskId,
            title: title,
            prompt: prompt,
            priority: priorityToInt(task.priority),
            dispatchCycle: dispatchCycle
        ) {
            // Dispatch succeeded — NOW mark active
            activeTasks.insert(taskId)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try? await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE tasks SET status = 'active', startedAt = ?, updatedAt = ? WHERE id = ?",
                    arguments: [now, now, taskId]
                )
            }
            // Fan-out to task watchers: pending → active. Status was pending
            // when the dispatcher picked it, so we can avoid a re-read.
            await fireTaskWatcherDMs(
                taskId: taskId, oldStatus: "pending", newStatus: "active", dbPool: dbPool
            )

            logger.info("Task \"\(title)\" dispatched via channel (event: \(eventId))")

            // Track for concurrency only — completion handled by /api/worker/events/complete
            Task.detached { [weak self] in
                guard let self = self else { return }
                let startTime = Date()
                let timeoutInterval: TimeInterval = 86400 // 24h safety timeout
                while true {
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                    let status: String? = try? await self.dbPool.read { db in
                        try String.fetchOne(db, sql: "SELECT status FROM tasks WHERE id = ?", arguments: [taskId])
                    }
                    if status == "completed" || status == "failed" || status == "cancelled" || status == "pending" {
                        await self.removeActiveTask(taskId)
                        break
                    }
                    // Safety: 24h timeout — just remove from active set, don't change task status
                    if Date().timeIntervalSince(startTime) > timeoutInterval {
                        await self.removeActiveTask(taskId)
                        break
                    }
                }
            }
            return
        }

        // Channel dispatch failed (no idle worker claimed the event in time).
        // Leave the task `pending` — the next poll cycle will retry once a
        // worker frees up. Bridge-only model: no `claude -p` fallback.
        logger.info("Channel dispatch missed for \"\(title)\" — leaving pending for next poll cycle")
    }

    private func priorityToInt(_ priority: String) -> Int {
        switch priority {
        case "critical": return 10
        case "high": return 8
        case "normal": return 5
        case "low": return 3
        case "backlog": return 1
        default: return 5
        }
    }

    private func removeActiveTask(_ taskId: String) {
        activeTasks.remove(taskId)
    }

    /// On startup, find tasks stuck in 'active' with no assigned worker event.
    /// These are orphans from prior crashes. Reset to 'pending' if active > 5 min.
    private func recoverOrphans() async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fiveMinAgo = now - 300_000
        do {
            try await dbPool.write { [logger] db in
                let orphans = try Row.fetchAll(db, sql: """
                    SELECT t.id, t.title, t.startedAt FROM tasks t
                    WHERE t.status = 'active'
                    AND (t.startedAt IS NULL OR t.startedAt < ?)
                    AND NOT EXISTS (
                        SELECT 1 FROM workerEvents e
                        WHERE json_extract(e.payload, '$.task_id') = t.id
                        AND e.status = 'assigned'
                    )
                """, arguments: [fiveMinAgo])

                for row in orphans {
                    let taskId = row["id"] as! String
                    let title = row["title"] as? String ?? taskId
                    try db.execute(sql: """
                        UPDATE tasks SET status = 'pending', startedAt = NULL, updatedAt = ?
                        WHERE id = ?
                    """, arguments: [now, taskId])
                    logger.info("Recovered orphaned task: \"\(title)\" (\(taskId))")
                }
                if !orphans.isEmpty {
                    logger.info("Recovered \(orphans.count) orphaned active task(s)")
                }
            }
        } catch {
            logger.error("Orphan recovery failed: \(error.localizedDescription)")
        }
    }

}

// Simple row type for reading tasks
private struct DispatcherTaskRow: FetchableRecord, Codable {
    let id: String
    let title: String
    let prompt: String?
    let model: String?
    let maxTurns: Int?
    let workingDir: String?
    let priority: String
    let blockedBy: String?

    static let databaseTableName = "tasks"
}
