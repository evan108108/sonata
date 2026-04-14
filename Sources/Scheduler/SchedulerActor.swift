import Foundation
import GRDB
import Logging

/// A scheduled job entry loaded from SQLite, used to build the run queue.
struct ScheduledEntry: Sendable {
    let id: String
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

/// Default no-op runner used when no real runner is registered.
struct StubClaudeRunner: ClaudeProcessRunner {
    func run(prompt: String, workingDir: String?, model: String?, maxTurns: Int?) async throws -> String? {
        nil
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

    /// Claude process runner — set via `setClaudeRunner`.
    private var claudeRunner: any ClaudeProcessRunner = StubClaudeRunner()

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
    func status() -> [(id: String, type: String, nextFire: Date)] {
        queue.map { ($0.entry.id, $0.entry.jobType.rawValue, $0.entry.nextFireTime) }
    }

    // MARK: - Job Loading

    /// Load enabled calendarEvents and scheduledJobs from SQLite into the queue.
    /// Applies stale job detection: jobs >1 hour overdue are skipped (one-shot) or advanced (recurring).
    private func loadJobs() async throws {
        let now = Date()
        let staleThreshold = now.addingTimeInterval(-Self.staleThresholdSeconds)

        // Load calendar events
        let calendarEntries: [(ScheduledEntry, JobSource)] = try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, prompt, scheduledAt, recurrence, taskType,
                       workingDir, model, maxTurns
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

                // Determine job type
                let jobType: ScheduledEntry.JobType
                switch taskTypeStr {
                case "spawn-claude": jobType = .spawnClaude
                case "shell": jobType = .shell
                case "internal": jobType = .internal
                default: jobType = .spawnClaude // default to claude for background jobs
                }

                // Determine next fire time with stale job detection
                var nextFire = scheduledAt
                if nextFire <= now, let rec = recurrence, let schedule = CronParser.parse(rec) {
                    // Recurring: advance past now
                    let interval = CronParser.recurrenceInterval(for: schedule)
                    while nextFire <= now {
                        nextFire = nextFire.addingTimeInterval(interval)
                    }
                } else if nextFire < staleThreshold {
                    // One-shot and stale (>1 hour overdue) — skip it
                    return nil
                } else if nextFire <= now {
                    // Recently due (within 1 hour) — fire normally
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

                return (ScheduledEntry(id: id, jobType: jobType, nextFireTime: nextFire, payload: payload), .calendarEvent)
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
                        let interval = CronParser.recurrenceInterval(for: schedule)
                        while nextFire <= now {
                            nextFire = nextFire.addingTimeInterval(interval)
                        }
                    } else if nextFire < staleThreshold {
                        // Stale one-shot scheduled job — skip
                        return nil
                    }
                } else if let schedule = CronParser.parse(scheduleStr) {
                    nextFire = CronParser.nextFire(for: schedule, after: now)
                } else {
                    return nil // Can't determine when to fire
                }

                let payload: ScheduledEntry.JobPayload = .shellCommand(command: command)
                return (ScheduledEntry(id: id, jobType: .shell, nextFireTime: nextFire, payload: payload), .scheduledJob)
            }
        }

        queue = (calendarEntries + scheduledEntries).sorted { $0.0.nextFireTime < $1.0.nextFireTime }

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
            // One-shot job — don't re-queue
            return
        }

        let nextFire = CronParser.nextFire(for: schedule, after: Date())
        let newEntry = ScheduledEntry(
            id: entry.id,
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
