import Foundation
import GRDB
import Logging

/// Polls for actionable tasks and dispatches them to Claude sessions.
///
/// Dispatch strategy:
/// 1. Try to push the task to an idle worker via the channel (SonataChannelServer).
///    Workers running Claude Code with `--dangerously-load-development-channels server:sonata-channel`
///    will pick it up through the MCP channel protocol.
/// 2. If no channel workers are available, fall back to spawning a headless `claude -p` process
///    via ClaudeProcessManager.
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
            """, arguments: [Int64(Date().timeIntervalSince1970 * 1000) - 60_000]) ?? 0
        }) ?? 0

        guard idleWorkerCount > 0 else { return }
        let slotsAvailable = idleWorkerCount  // one task per idle worker

        // Find actionable tasks: pending, assigned to scheduler, not blocked
        let tasks = try await dbPool.read { db -> [OrchestratorTaskRow] in
            try OrchestratorTaskRow.fetchAll(db, sql: """
                SELECT * FROM tasks
                WHERE status = 'pending'
                AND (assignedTo = 'scheduler' OR assignedTo IS NULL)
                AND (blockedBy IS NULL OR blockedBy = '[]' OR blockedBy = '')
                ORDER BY
                    CASE priority
                        WHEN 'critical' THEN 0
                        WHEN 'high' THEN 1
                        WHEN 'normal' THEN 2
                        WHEN 'low' THEN 3
                        WHEN 'backlog' THEN 4
                    END,
                    createdAt ASC
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

        // Strategy 2: Fall back to headless claude -p process
        logger.info("No channel workers — falling back to ClaudeProcessManager for \"\(title)\"")

        // Mark active only after confirming we can run it
        activeTasks.insert(taskId)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? await dbPool.write { db in
            try db.execute(
                sql: "UPDATE tasks SET status = 'active', startedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, taskId]
            )
        }

        if let workerId = try? await findIdleWorker() {
            try? await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE workers SET status = 'busy', currentEventId = ? WHERE workerId = ?",
                    arguments: [taskId, workerId]
                )
            }
        }

        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                let model = task.model ?? "claude-opus-4-6"
                let maxTurns = task.maxTurns ?? 300
                let cwd = task.workingDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("memory").path

                let result = try await ClaudeProcessManager.run(
                    prompt: prompt,
                    model: model,
                    maxTurns: maxTurns,
                    label: "task:\(title.prefix(30))",
                    cwd: cwd,
                    timeoutMs: 600_000
                )

                await self.completeTask(taskId: taskId, result: result)
            } catch {
                await self.failTask(taskId: taskId, error: error.localizedDescription)
            }
        }
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

    private func completeTask(taskId: String, result: ClaudeResult) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let summary = "Completed: \(result.numTurns) turns, $\(String(format: "%.4f", result.totalCost)), \(result.durationMs)ms"

        logger.info("Task \(taskId) completed: \(summary)")

        try? await dbPool.write { db in
            // Mark task complete
            try db.execute(
                sql: "UPDATE tasks SET status = 'completed', result = ?, completedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [summary, now, now, taskId]
            )

            // Unblock dependent tasks
            try unblockDependents(taskId: taskId, in: db, now: now)
        }

        // Reset worker to idle
        try? await dbPool.write { db in
            try db.execute(
                sql: "UPDATE workers SET status = 'idle', currentEventId = NULL WHERE currentEventId = ?",
                arguments: [taskId]
            )
        }

        activeTasks.remove(taskId)
    }

    private func failTask(taskId: String, error: String) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        logger.error("Task \(taskId) failed: \(error)")

        try? await dbPool.write { db in
            try db.execute(
                sql: "UPDATE tasks SET status = 'failed', lastError = ?, updatedAt = ? WHERE id = ?",
                arguments: [error, now, taskId]
            )

            // Unblock dependent tasks so they don't stay stuck forever
            try unblockDependents(taskId: taskId, in: db, now: now)
        }

        // Reset worker to idle
        try? await dbPool.write { db in
            try db.execute(
                sql: "UPDATE workers SET status = 'idle', currentEventId = NULL WHERE currentEventId = ?",
                arguments: [taskId]
            )
        }

        activeTasks.remove(taskId)
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

    private func findIdleWorker() async throws -> String? {
        try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT workerId FROM workers WHERE status = 'idle' LIMIT 1")
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
