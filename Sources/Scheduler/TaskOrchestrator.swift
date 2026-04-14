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
    private let maxConcurrent = 2

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
        logger.info("TaskOrchestrator started (polling every 10s, max \(maxConcurrent) concurrent)")
        Task { await pollLoop() }
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
        // Don't dispatch if at capacity
        let currentCount = activeTasks.count
        guard currentCount < maxConcurrent else { return }
        let slotsAvailable = maxConcurrent - currentCount

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
            let isActive = activeTasks.contains(task.id)
            let atCapacity = activeTasks.count >= maxConcurrent
            guard !isActive, !atCapacity else { continue }
            await dispatch(task)
        }
    }

    private func dispatch(_ task: OrchestratorTaskRow) async {
        let taskId = task.id
        let title = task.title
        let prompt = task.prompt ?? task.title
        activeTasks.insert(taskId)

        logger.info("Dispatching: \"\(title)\" (\(taskId))")

        // Mark as active
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? await dbPool.write { db in
            try db.execute(
                sql: "UPDATE tasks SET status = 'active', startedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, taskId]
            )
        }

        // Strategy 1: Try channel dispatch to an idle TUI worker
        if let eventId = await channelServer.dispatchToChannel(
            taskId: taskId,
            title: title,
            prompt: prompt,
            priority: priorityToInt(task.priority)
        ) {
            logger.info("Task \"\(title)\" dispatched via channel (event: \(eventId))")

            // Wait for completion in a detached task
            Task.detached { [weak self] in
                guard let self = self else { return }
                let (success, detail) = await self.channelServer.waitForCompletion(
                    eventId: eventId,
                    timeoutMs: 600_000
                )
                if success {
                    let result = ClaudeResult(
                        numTurns: 0, totalCost: 0, durationMs: 0, peakContext: 0,
                        isError: false, errorMessage: nil, sessionId: nil
                    )
                    await self.completeTask(taskId: taskId, result: result)
                } else {
                    await self.failTask(taskId: taskId, error: detail ?? "Channel dispatch failed")
                }
            }
            return
        }

        // Strategy 2: Fall back to headless claude -p process
        logger.info("No channel workers — falling back to ClaudeProcessManager for \"\(title)\"")

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

            // Unblock dependent tasks — remove this ID from other tasks' blockedBy arrays
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
