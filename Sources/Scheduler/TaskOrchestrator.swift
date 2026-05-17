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
actor TaskOrchestrator {
    private let dbPool: DatabasePool
    private let logger: Logger
    private let channelServer: SonataChannelServer
    private var isRunning = false
    private var activeTasks: Set<String> = []  // task IDs currently being executed

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        self.channelServer = SonataChannelServer(dbPool: dbPool)
        var logger = Logger(label: "sonata.orchestrator")
        logger.logLevel = .info
        self.logger = logger
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("TaskOrchestrator started (polling every 10s, dynamic concurrency)")
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
                logger.error("Orchestrator poll error: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
        }
    }

    private func poll() async throws {
        // Dynamic concurrency: match available idle workers
        let idleWorkerCount: Int = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM workers
                WHERE status = 'idle' AND lastHeartbeat >= ?
            """, arguments: [Int64(Date().timeIntervalSince1970 * 1000) - 30_000]) ?? 0
        }) ?? 0

        guard idleWorkerCount > 0 else { return }
        let slotsAvailable = idleWorkerCount  // one task per idle worker

        // Find actionable tasks: pending, assigned to scheduler, not blocked,
        // and leaf-only (parent/container tasks with subtasks are skipped —
        // they have no prompt and would waste worker turns).
        let tasks = try await dbPool.read { db -> [OrchestratorTaskRow] in
            try OrchestratorTaskRow.fetchAll(db, sql: """
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

        for task in tasks {
            guard !activeTasks.contains(task.id) else { continue }
            await dispatch(task)
        }
    }

    private func dispatch(_ task: OrchestratorTaskRow) async {
        let taskId = task.id
        let title = task.title
        let prompt = task.prompt ?? task.title

        logger.info("Dispatching: \"\(title)\" (\(taskId))")

        // Strategy 1: Try channel dispatch to an idle TUI worker
        if let eventId = await channelServer.dispatchToChannel(
            taskId: taskId,
            title: title,
            prompt: prompt,
            priority: priorityToInt(task.priority)
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
private struct OrchestratorTaskRow: FetchableRecord, Codable {
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
