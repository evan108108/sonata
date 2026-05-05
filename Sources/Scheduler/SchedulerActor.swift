import Foundation
import GRDB
import Logging

/// A scheduled job entry loaded from SQLite, used to build the run queue.
struct ScheduledEntry: Sendable {
    let id: String
    let name: String
    let jobType: JobType
    let nextFireTime: Date
    let payload: JobPayload

    enum JobType: String, Sendable {
        case spawnClaude = "spawn-claude"
        case shell = "shell"
        case `internal` = "internal"
    }

    /// What to execute when the job fires.
    enum JobPayload: Sendable {
        /// Spawn a Claude Code session with the given prompt, working dir, model, maxTurns.
        case claude(prompt: String, workingDir: String?, model: String?, maxTurns: Int?)
        /// Run a shell command.
        case shellCommand(command: String)
        /// Call a registered Swift function by name.
        case internalFunc(name: String)
    }
}

/// Source table for a scheduled entry (needed for post-run updates).
enum JobSource: Sendable {
    case calendarEvent
    case scheduledJob
}

/// Protocol for the Claude process manager — implemented externally.
/// Keeps the scheduler decoupled from the actual Claude SDK integration.
protocol ClaudeProcessRunner: Sendable {
    func run(prompt: String, workingDir: String?, model: String?, maxTurns: Int?) async throws -> String?
}

/// Default runner that creates a task for the TaskOrchestrator to dispatch via channel.
struct DefaultClaudeRunner: ClaudeProcessRunner {
    let dbPool: DatabasePool

    func run(prompt: String, workingDir: String?, model: String?, maxTurns: Int?) async throws -> String? {
        let taskId = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let title = String(prompt.prefix(80))

        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, title, prompt, status, priority, assignedTo, source, workingDir, model, maxTurns, createdAt, updatedAt)
                VALUES (?, ?, ?, 'pending', 'high', 'scheduler', 'scheduler', ?, ?, ?, ?, ?)
            """, arguments: [taskId, title, prompt, workingDir, model, maxTurns, now, now])
        }

        return "Task created: \(taskId)"
    }
}

// MARK: - SchedulerActor

/// Manages all timed jobs — replaces both Convex crons.ts and parts of sona-scheduler.js.
///
/// Thread-safe via Swift actor isolation. Uses a single `Task.sleep`-based loop
/// that wakes at the earliest due time, executes the job, updates SQLite, and
/// re-queues recurring events.
public actor SchedulerActor {

    // MARK: - State

    /// Priority queue: sorted ascending by nextFireTime.
    private var queue: [(entry: ScheduledEntry, source: JobSource)] = []

    /// The main scheduler loop task — cancelled on shutdown.
    private var loopTask: Task<Void, Never>?

    /// Database pool for reading/updating job state.
    private let dbPool: DatabasePool

    /// Logger instance.
    private let logger: Logger

    /// Claude process runner — creates tasks for orchestrator dispatch.
    private var claudeRunner: any ClaudeProcessRunner

    /// Registered internal functions, keyed by name.
    private var internalFunctions: [String: @Sendable () async throws -> Void] = [:]

    /// Whether the actor has been started.
    private var isRunning = false

    /// Maximum number of jobs to fire simultaneously on startup.
    private let maxConcurrentJobs = 3

    /// Number of currently running jobs.
    private var activeJobCount = 0

    /// Jobs waiting to run due to concurrency limit.
    private var pendingJobs: [(entry: ScheduledEntry, source: JobSource)] = []

    /// Staleness threshold: jobs older than this are skipped on startup (1 hour).
    private static let staleThresholdSeconds: TimeInterval = 3600

    // MARK: - Init

    init(dbPool: DatabasePool, logger: Logger? = nil) {
        self.dbPool = dbPool
        self.claudeRunner = DefaultClaudeRunner(dbPool: dbPool)
        var log = logger ?? Logger(label: "sonata.scheduler")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Configuration

    /// Register the Claude process runner (called during app startup).
    func setClaudeRunner(_ runner: any ClaudeProcessRunner) {
        self.claudeRunner = runner
    }

    /// Register an internal Swift function that can be triggered by name.
    func registerInternal(_ name: String, handler: @escaping @Sendable () async throws -> Void) {
        internalFunctions[name] = handler
    }

    // MARK: - Lifecycle

    /// Load jobs from SQLite and start the scheduler loop.
    func start() async {
        guard !isRunning else {
            logger.warning("Scheduler already running — ignoring duplicate start()")
            return
        }
        isRunning = true

        do {
            try await loadJobs()
        } catch {
            logger.error("Failed to load jobs from SQLite: \(error)")
        }

        logger.info("Scheduler started with \(queue.count) jobs queued")
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Gracefully shut down: cancel pending timers, stop the loop.
    func shutdown() {
        logger.info("Scheduler shutting down")
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        queue.removeAll()
    }

    /// Trigger a specific job immediately by its DB id, regardless of schedule.
    func triggerNow(jobId: String) async {
        // Find the job in the queue
        if let idx = queue.firstIndex(where: { $0.entry.id == jobId }) {
            let (entry, source) = queue.remove(at: idx)
            logger.info("Triggering job \"\(entry.name)\" immediately")
            await fireJob(entry: entry, source: source)
            return
        }
        // Not in queue — load it from DB directly
        do {
            // Try scheduledJobs first
            let row: Row? = try await dbPool.read { db in
                try Row.fetchOne(db, sql: "SELECT id, name, schedule, command FROM scheduledJobs WHERE id = ?", arguments: [jobId])
            }
            if let row = row, let id = row["id"] as? String,
               let command = row["command"] as? String {
                let name = row["name"] as? String ?? id
                let entry = ScheduledEntry(id: id, name: name, jobType: .shell, nextFireTime: Date(), payload: .shellCommand(command: command))
                logger.info("Triggering job \"\(name)\" immediately (loaded from DB)")
                await fireJob(entry: entry, source: .scheduledJob)
                return
            }
            // Try calendarEvents
            let calRow: Row? = try await dbPool.read { db in
                try Row.fetchOne(db, sql: "SELECT id, title, prompt, taskType, workingDir, model, maxTurns FROM calendarEvents WHERE id = ?", arguments: [jobId])
            }
            if let row = calRow, let id = row["id"] as? String {
                let title = row["title"] as? String ?? id
                let prompt = row["prompt"] as? String ?? title
                let workingDir = row["workingDir"] as? String
                let model = row["model"] as? String
                let maxTurns = row["maxTurns"] as? Int
                let payload: ScheduledEntry.JobPayload = .claude(prompt: prompt, workingDir: workingDir, model: model, maxTurns: maxTurns)
                let entry = ScheduledEntry(id: id, name: title, jobType: .spawnClaude, nextFireTime: Date(), payload: payload)
                logger.info("Triggering calendar event \"\(title)\" immediately (loaded from DB)")
                await fireJob(entry: entry, source: .calendarEvent)
                return
            }
            logger.warning("triggerNow: job \(jobId) not found in queue or DB")
        } catch {
            logger.error("triggerNow failed: \(error)")
        }
    }

    /// Reload all jobs from the database (e.g. after external edits via HTTP API).
    func reload() async {
        queue.removeAll()
        do {
            try await loadJobs()
            logger.info("Scheduler reloaded: \(queue.count) jobs queued")
        } catch {
            logger.error("Failed to reload jobs: \(error)")
        }
        // Wake the loop by cancelling and restarting it
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Returns the current queue state for diagnostics.
    func status() -> [(id: String, name: String, type: String, nextFire: Date)] {
        queue.map { ($0.entry.id, $0.entry.name, $0.entry.jobType.rawValue, $0.entry.nextFireTime) }
    }

    // MARK: - Job Loading

    /// Load enabled calendarEvents and scheduledJobs from SQLite into the queue.
    /// Applies stale job detection: jobs >1 hour overdue are skipped (one-shot) or advanced (recurring).
    private func loadJobs() async throws {
        let now = Date()
        let staleThreshold = now.addingTimeInterval(-Self.staleThresholdSeconds)

        // Load calendar events
        let logger = self.logger
        let calendarEntries: [(ScheduledEntry, JobSource)] = try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, prompt, scheduledAt, recurrence, taskType,
                       workingDir, model, maxTurns, createdAt
                FROM calendarEvents
                WHERE enabled = 1
            """)

            return rows.compactMap { row -> (ScheduledEntry, JobSource)? in
                guard let id = row["id"] as? String,
                      let taskTypeStr = row["taskType"] as? String,
                      let scheduledAtMs = row["scheduledAt"] as? Int64
                else { return nil }

                let scheduledAt = Date(timeIntervalSince1970: Double(scheduledAtMs) / 1000.0)
                let prompt = row["prompt"] as? String
                let recurrence = row["recurrence"] as? String
                let workingDir = row["workingDir"] as? String
                let model = row["model"] as? String
                let maxTurns = row["maxTurns"] as? Int
                let createdAt = (row["createdAt"] as? Int64).map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                let title = row["title"] as? String ?? id

                // Determine job type
                let jobType: ScheduledEntry.JobType
                switch taskTypeStr {
                case "spawn-claude": jobType = .spawnClaude
                case "shell": jobType = .shell
                case "internal": jobType = .internal
                default: jobType = .spawnClaude // default to claude for background jobs
                }

                // Determine next fire time with stale job detection.
                // A one-shot is only "stale" if BOTH its scheduledAt is >1h past
                // AND it was created >1h ago. A freshly-created event with a past
                // scheduledAt should still fire — it just hasn't been seen yet.
                var nextFire = scheduledAt
                if nextFire <= now, let rec = recurrence, let schedule = CronParser.parse(rec) {
                    // Recurring: compute next fire directly
                    nextFire = CronParser.nextFire(for: schedule, after: now)
                } else if nextFire < staleThreshold && (createdAt.map { $0 < staleThreshold } ?? true) {
                    // One-shot, fire time AND creation both >1h past — drop as stale
                    logger.warning("Skipping stale calendar event \(id) (\"\(title)\"): scheduledAt=\(scheduledAt), createdAt=\(createdAt.map { "\($0)" } ?? "nil")")
                    return nil
                } else if nextFire <= now {
                    // Recently due (within 1h) OR freshly created with past scheduledAt — fire soon
                    nextFire = now.addingTimeInterval(1)
                }

                let payload: ScheduledEntry.JobPayload
                switch jobType {
                case .spawnClaude:
                    payload = .claude(
                        prompt: prompt ?? "Run scheduled task: \(row["title"] as? String ?? id)",
                        workingDir: workingDir,
                        model: model,
                        maxTurns: maxTurns
                    )
                case .shell:
                    payload = .shellCommand(command: prompt ?? "")
                case .internal:
                    payload = .internalFunc(name: prompt ?? taskTypeStr)
                }

                return (ScheduledEntry(id: id, name: title, jobType: jobType, nextFireTime: nextFire, payload: payload), .calendarEvent)
            }
        }

        // Load scheduled jobs
        let scheduledEntries: [(ScheduledEntry, JobSource)] = try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, schedule, command, nextRunAt
                FROM scheduledJobs
                WHERE enabled = 1
            """)

            return rows.compactMap { row -> (ScheduledEntry, JobSource)? in
                guard let id = row["id"] as? String,
                      let scheduleStr = row["schedule"] as? String,
                      let command = row["command"] as? String
                else { return nil }

                // Parse schedule for next fire time
                let nextRunAtRaw = row["nextRunAt"] as? Double
                var nextFire: Date
                if let ts = nextRunAtRaw, ts > 0 {
                    nextFire = Date(timeIntervalSince1970: ts / 1000.0)
                    if nextFire <= now, let schedule = CronParser.parse(scheduleStr) {
                        // Use nextFire() directly — avoids slow loop for cron schedules
                        nextFire = CronParser.nextFire(for: schedule, after: now)
                    } else if nextFire < staleThreshold {
                        // Stale one-shot scheduled job — skip
                        return nil
                    }
                } else if let schedule = CronParser.parse(scheduleStr) {
                    nextFire = CronParser.nextFire(for: schedule, after: now)
                } else {
                    return nil // Can't determine when to fire
                }

                let name = row["name"] as? String ?? id
                let payload: ScheduledEntry.JobPayload = .shellCommand(command: command)
                return (ScheduledEntry(id: id, name: name, jobType: .shell, nextFireTime: nextFire, payload: payload), .scheduledJob)
            }
        }

        queue = (calendarEntries + scheduledEntries).sorted { $0.0.nextFireTime < $1.0.nextFireTime }

        // Persist computed nextFire times back to DB so the UI stays in sync
        try await dbPool.write { db in
            for (entry, source) in calendarEntries {
                let nextMs = Int64(entry.nextFireTime.timeIntervalSince1970 * 1000)
                switch source {
                case .calendarEvent:
                    try db.execute(sql: "UPDATE calendarEvents SET scheduledAt = ?, updatedAt = ? WHERE id = ?",
                                   arguments: [nextMs, nextMs, entry.id])
                case .scheduledJob:
                    break
                }
            }
            for (entry, source) in scheduledEntries {
                let nextMs = entry.nextFireTime.timeIntervalSince1970 * 1000
                switch source {
                case .scheduledJob:
                    try db.execute(sql: "UPDATE scheduledJobs SET nextRunAt = ? WHERE id = ?",
                                   arguments: [nextMs, entry.id])
                case .calendarEvent:
                    break
                }
            }
        }

        // Count how many enabled rows existed vs how many made it into the queue
        let totalEnabled: Int = try await dbPool.read { db in
            let calCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendarEvents WHERE enabled = 1") ?? 0
            let jobCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduledJobs WHERE enabled = 1") ?? 0
            return calCount + jobCount
        }
        let staleCount = totalEnabled - queue.count
        if staleCount > 0 {
            logger.info("Scheduler: skipped \(staleCount) stale jobs, scheduling \(queue.count) active jobs")
        }
    }

    // MARK: - Main Loop

    /// The core scheduler loop. Sleeps until the next job is due, executes it,
    /// updates SQLite, and re-queues recurring jobs.
    private func runLoop() async {
        while !Task.isCancelled {
            guard let next = queue.first else {
                // No jobs — sleep for 60s then check again (new jobs may have been added via reload)
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break // Cancelled
                }
                continue
            }

            let now = Date()
            let delay = next.entry.nextFireTime.timeIntervalSince(now)

            if delay > 0 {
                // Sleep until the next job is due
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break // Cancelled during sleep — shut down gracefully
                }

                // Re-check: queue may have changed during sleep (via reload)
                if Task.isCancelled { break }
                continue // Loop back to re-evaluate the head of the queue
            }

            // Job is due — pop it
            let (entry, source) = queue.removeFirst()

            // Enforce max concurrent jobs
            if activeJobCount >= maxConcurrentJobs {
                logger.info("Concurrency limit reached (\(maxConcurrentJobs)), queueing job \(entry.id)")
                pendingJobs.append((entry: entry, source: source))
                continue
            }

            await fireJob(entry: entry, source: source)
        }

        logger.info("Scheduler loop exited")
    }

    // MARK: - Job Execution

    /// Fire a job in a detached task with concurrency tracking.
    private func fireJob(entry: ScheduledEntry, source: JobSource) async {
        activeJobCount += 1

        let dbPool = self.dbPool
        let logger = self.logger
        let claudeRunner = self.claudeRunner
        let internalFunctions = self.internalFunctions

        Task.detached { [weak self] in
            var runStatus = "success"
            var resultText: String? = nil
            var errorText: String? = nil

            do {
                switch entry.payload {
                case .claude(let prompt, let workingDir, let model, let maxTurns):
                    logger.info("Firing spawn-claude job \(entry.id)")
                    resultText = try await claudeRunner.run(
                        prompt: prompt,
                        workingDir: workingDir,
                        model: model,
                        maxTurns: maxTurns
                    )

                case .shellCommand(let command):
                    logger.info("Firing shell job \(entry.id): \(command.prefix(80))")
                    resultText = try await SchedulerActor.runShellCommand(command)

                case .internalFunc(let name):
                    logger.info("Firing internal job \(entry.id): \(name)")
                    if let fn = internalFunctions[name] {
                        try await fn()
                    } else {
                        throw SchedulerError.unknownInternalFunction(name)
                    }
                }
            } catch {
                runStatus = "error"
                errorText = String(describing: error)
                logger.error("Job \(entry.id) failed: \(error)")
            }

            let finalStatus = runStatus
            let finalResult = resultText
            let finalError = errorText

            // Update SQLite with run results
            do {
                try await dbPool.write { db in
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    switch source {
                    case .calendarEvent:
                        try db.execute(sql: """
                            UPDATE calendarEvents
                            SET lastRunAt = ?, lastRunStatus = ?, runCount = runCount + 1, updatedAt = ?
                            WHERE id = ?
                        """, arguments: [nowMs, finalStatus, nowMs, entry.id])

                    case .scheduledJob:
                        let nowSec = Date().timeIntervalSince1970 * 1000
                        try db.execute(sql: """
                            UPDATE scheduledJobs
                            SET lastRunAt = ?, lastResult = ?, lastError = ?, lastExitCode = ?
                            WHERE id = ?
                        """, arguments: [nowSec, finalResult, finalError, finalStatus == "success" ? 0 : 1, entry.id])
                    }
                }
            } catch {
                logger.error("Failed to update job \(entry.id) after execution: \(error)")
            }

            // Signal completion back to the actor
            await self?.jobCompleted(entry: entry, source: source)
        }

        // Re-queue if recurring
        await requeue(entry: entry, source: source)
    }

    /// Called when a detached job task finishes. Decrements active count and drains pending queue.
    private func jobCompleted(entry: ScheduledEntry, source: JobSource) {
        activeJobCount -= 1
        drainPendingJobs()
    }

    /// Fire pending jobs up to the concurrency limit.
    private func drainPendingJobs() {
        while activeJobCount < maxConcurrentJobs, !pendingJobs.isEmpty {
            let (entry, source) = pendingJobs.removeFirst()
            Task { [weak self] in
                await self?.fireJob(entry: entry, source: source)
            }
        }
    }

    // MARK: - Requeue

    /// For recurring jobs, compute the next fire time and re-insert into the sorted queue.
    private func requeue(entry: ScheduledEntry, source: JobSource) async {
        let recurrence: String?

        switch source {
        case .calendarEvent:
            recurrence = try? await dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT recurrence FROM calendarEvents WHERE id = ?", arguments: [entry.id])
            }
        case .scheduledJob:
            recurrence = try? await dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT schedule FROM scheduledJobs WHERE id = ?", arguments: [entry.id])
            }
        }

        guard let rec = recurrence, let schedule = CronParser.parse(rec) else {
            // One-shot job — disable it so the UI shows "completed" instead of "overdue"
            if case .calendarEvent = source {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                try? await dbPool.write { db in
                    try db.execute(sql: "UPDATE calendarEvents SET enabled = 0, updatedAt = ? WHERE id = ?",
                                   arguments: [nowMs, entry.id])
                }
            }
            return
        }

        let nextFire = CronParser.nextFire(for: schedule, after: Date())
        let newEntry = ScheduledEntry(
            id: entry.id,
            name: entry.name,
            jobType: entry.jobType,
            nextFireTime: nextFire,
            payload: entry.payload
        )

        // Insert in sorted position
        let insertIndex = queue.firstIndex { $0.entry.nextFireTime > nextFire } ?? queue.endIndex
        queue.insert((newEntry, source), at: insertIndex)

        // Update nextRunAt in scheduledJobs table
        if case .scheduledJob = source {
            let nextMs = nextFire.timeIntervalSince1970 * 1000
            try? await dbPool.write { db in
                try db.execute(sql: "UPDATE scheduledJobs SET nextRunAt = ? WHERE id = ?",
                               arguments: [nextMs, entry.id])
            }
        }

        // Update scheduledAt for recurring calendarEvents
        if case .calendarEvent = source {
            let nextMs = Int64(nextFire.timeIntervalSince1970 * 1000)
            try? await dbPool.write { db in
                try db.execute(sql: "UPDATE calendarEvents SET scheduledAt = ?, updatedAt = ? WHERE id = ?",
                               arguments: [nextMs, nextMs, entry.id])
            }
        }
    }

    // MARK: - Shell Execution

    /// Run a shell command and capture its stdout. Timeout: 5 minutes.
    private static func runShellCommand(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Timeout: 5 minutes
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + 300)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                continuation.resume(returning: output)
            } else {
                continuation.resume(throwing: SchedulerError.shellFailed(
                    exitCode: process.terminationStatus,
                    output: output
                ))
            }
        }
    }
}

// MARK: - Errors

enum SchedulerError: Error, LocalizedError {
    case unknownInternalFunction(String)
    case shellFailed(exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .unknownInternalFunction(let name):
            return "No internal function registered with name '\(name)'"
        case .shellFailed(let code, let output):
            return "Shell command exited with code \(code): \(output.prefix(500))"
        }
    }
}
