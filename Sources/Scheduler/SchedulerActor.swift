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
    /// Optional DM target for the "notify a session instead of spawning a
    /// worker" path (v43 notifyTarget column). When set AND resolves to a
    /// live target at fire time, the scheduler DMs `notifyBodyText()` to the
    /// target and skips worker spawn / shell exec. On not_live/not_found it
    /// falls back to the payload's normal path so a durable schedule still
    /// fires. `nil` (the vast majority of rows) fires as it always has.
    let notifyTarget: String?

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

    /// Text payload the scheduler DMs when `notifyTarget` is set and resolves.
    /// Callers only reach this when the payload has a natural text body
    /// (claude prompt, shell command). Internal-function payloads don't
    /// have a body and take the normal fire path even with `notifyTarget`
    /// set — that path is checked at the fire site.
    func notifyBodyText() -> String? {
        switch payload {
        case .claude(let prompt, _, _, _):
            return prompt
        case .shellCommand(let command):
            return command
        case .internalFunc:
            return nil
        }
    }
}

/// Source table for a scheduled entry (needed for post-run updates).
enum JobSource: Sendable {
    case calendarEvent
    case scheduledJob
}

/// Protocol for the Claude process manager — implemented externally.
/// Keeps the scheduler decoupled from the actual Claude SDK integration.
///
/// `jobId` is the id of the calendarEvent/scheduledJob that fired. It is persisted
/// on the task as `sourceRef` so a recurring job's runs can be coalesced: see
/// `DefaultClaudeRunner.run`.
protocol ClaudeProcessRunner: Sendable {
    func run(jobId: String, prompt: String, workingDir: String?, model: String?, maxTurns: Int?) async throws -> String?
}

/// Default runner that creates a task for the TaskDispatcher to dispatch via channel.
struct DefaultClaudeRunner: ClaudeProcessRunner {
    let dbPool: DatabasePool

    func run(jobId: String, prompt: String, workingDir: String?, model: String?, maxTurns: Int?) async throws -> String? {
        let taskId = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let title = String(prompt.prefix(80))

        let superseded: Int = try await dbPool.write { db in
            // Coalesce: a recurring job never needs more than its most recent run
            // pending at once. If the previous run is still undispatched (no idle
            // worker claimed it — the whole backend can be up with zero attached
            // workers, in which case TaskDispatcher.poll() returns early and tasks
            // accumulate), retire it in favour of this one.
            //
            // Without this, an outage that spans N firings leaves N pending tasks
            // that all drain the moment a worker reappears — N full workers running
            // the same job minutes apart, each against a work manifest snapshotted
            // days earlier. Observed 2026-07-13: a 3-day worker gap (7/10-7/12)
            // queued 4 toolWatch runs and 4 wiki compilations; on drain, a worker
            // executed a 79-hour-old "12 pages" manifest against a wiki a peer had
            // already recompiled.
            try db.execute(sql: """
                UPDATE tasks
                SET status = 'cancelled', lastError = ?, updatedAt = ?
                WHERE source = 'scheduler' AND sourceRef = ? AND status = 'pending'
            """, arguments: ["superseded by a newer run of the same scheduled job", now, jobId])
            let count = db.changesCount

            try db.execute(sql: """
                INSERT INTO tasks (id, title, prompt, status, priority, assignedTo, source, sourceRef, workingDir, model, maxTurns, createdAt, updatedAt)
                VALUES (?, ?, ?, 'pending', 'high', 'scheduler', 'scheduler', ?, ?, ?, ?, ?, ?)
            """, arguments: [taskId, title, prompt, jobId, workingDir, model, maxTurns, now, now])

            return count
        }

        if superseded > 0 {
            return "Task created: \(taskId) (superseded \(superseded) undispatched run(s) of job \(jobId))"
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

    /// Claude process runner — creates tasks for dispatcher dispatch.
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
            let row: Row? = try dbPool.read { db in
                try Row.fetchOne(db, sql: "SELECT id, name, schedule, command, notifyTarget FROM scheduledJobs WHERE id = ?", arguments: [jobId])
            }
            if let row = row, let id = row["id"] as? String,
               let command = row["command"] as? String {
                let name = row["name"] as? String ?? id
                let notifyTarget = row["notifyTarget"] as? String
                let entry = ScheduledEntry(id: id, name: name, jobType: .shell, nextFireTime: Date(), payload: .shellCommand(command: command), notifyTarget: notifyTarget)
                logger.info("Triggering job \"\(name)\" immediately (loaded from DB)")
                await fireJob(entry: entry, source: .scheduledJob)
                return
            }
            // Try calendarEvents
            let calRow: Row? = try dbPool.read { db in
                try Row.fetchOne(db, sql: "SELECT id, title, prompt, taskType, workingDir, model, maxTurns, notifyTarget FROM calendarEvents WHERE id = ?", arguments: [jobId])
            }
            if let row = calRow, let id = row["id"] as? String {
                let title = row["title"] as? String ?? id
                let prompt = row["prompt"] as? String ?? title
                let workingDir = row["workingDir"] as? String
                let model = row["model"] as? String
                let maxTurns = row["maxTurns"] as? Int
                let notifyTarget = row["notifyTarget"] as? String
                let payload: ScheduledEntry.JobPayload = .claude(prompt: prompt, workingDir: workingDir, model: model, maxTurns: maxTurns)
                let entry = ScheduledEntry(id: id, name: title, jobType: .spawnClaude, nextFireTime: Date(), payload: payload, notifyTarget: notifyTarget)
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
                       workingDir, model, maxTurns, notifyTarget, createdAt
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
                let notifyTarget = row["notifyTarget"] as? String
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

                return (ScheduledEntry(id: id, name: title, jobType: jobType, nextFireTime: nextFire, payload: payload, notifyTarget: notifyTarget), .calendarEvent)
            }
        }

        // Load scheduled jobs
        let scheduledEntries: [(ScheduledEntry, JobSource)] = try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, schedule, command, nextRunAt, notifyTarget
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
                let notifyTarget = row["notifyTarget"] as? String
                let payload: ScheduledEntry.JobPayload = .shellCommand(command: command)
                return (ScheduledEntry(id: id, name: name, jobType: .shell, nextFireTime: nextFire, payload: payload, notifyTarget: notifyTarget), .scheduledJob)
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

            // notify_target branch (v43). If the schedule row carries a
            // notifyTarget AND the payload has a text body worth DMing,
            // try to DM that target first. On sent → skip normal execution.
            // On not_live/not_found → fall through to today's exec path so
            // the schedule still fires. `.internalFunc` payloads have no
            // DM body; they always take the exec path.
            var dmAttempted = false
            var dmSucceeded = false
            if let target = entry.notifyTarget, !target.isEmpty,
               let bodyText = entry.notifyBodyText() {
                dmAttempted = true
                let outcome = await SchedulerActor.attemptScheduledNotify(
                    target: target,
                    bodyText: bodyText,
                    entryId: entry.id,
                    source: source,
                    dbPool: dbPool,
                    logger: logger
                )
                switch outcome {
                case .sent(let messageId):
                    dmSucceeded = true
                    resultText = "notified \(target) (dm \(messageId))"
                    logger.info("Job \(entry.id): DMed notifyTarget=\(target) instead of spawning worker")
                case .fellBackNotLive(let reason):
                    logger.warning("Job \(entry.id): notifyTarget=\(target) not live at fire (\(reason)) — falling back to worker spawn")
                case .fellBackNotFound(let reason):
                    logger.warning("Job \(entry.id): notifyTarget=\(target) not found at fire (\(reason)) — falling back to worker spawn")
                }
            }

            if !dmSucceeded {
                do {
                    switch entry.payload {
                    case .claude(let prompt, let workingDir, let model, let maxTurns):
                        logger.info("Firing spawn-claude job \(entry.id)")
                        resultText = try await claudeRunner.run(
                            jobId: entry.id,
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

                if dmAttempted {
                    // Prepend a marker so the audit row makes clear we tried
                    // to DM first and only spawned as a fallback.
                    let prefix = "notify_target fallback (spawned worker/exec): "
                    resultText = prefix + (resultText ?? "")
                }
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
            payload: entry.payload,
            notifyTarget: entry.notifyTarget
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

    // MARK: - notify_target DM path (v43)

    /// Outcome of a scheduled fire's DM attempt. `sent` means the DM landed
    /// on a live target and normal execution is skipped; the two fallback
    /// cases mean the target wasn't reachable at fire time so the caller
    /// runs the payload's usual path (spawn worker / shell exec).
    enum NotifyOutcome: Sendable {
        case sent(messageId: String)
        case fellBackNotLive(reason: String)
        case fellBackNotFound(reason: String)
    }

    /// Wrap the raw payload text (claude prompt or shell command) with a
    /// preamble identifying the schedule row and the fire time. Extracted
    /// so tests can assert the exact on-the-wire body shape without going
    /// through the DM resolver.
    ///
    /// Contract:
    ///   calendar_create rows → `[scheduled reminder from calendar_event/<id>, fired at <iso>]\n\n<body>`
    ///   scheduler_create rows → `[scheduled reminder from scheduler_job/<id>, fired at <iso>]\n\n<body>`
    static func wrappedNotifyBody(
        bodyText: String,
        entryId: String,
        source: JobSource,
        firedAt: Date
    ) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let firedAtIso = iso.string(from: firedAt)
        let originPrefix: String
        switch source {
        case .calendarEvent: originPrefix = "calendar_event/\(entryId)"
        case .scheduledJob:  originPrefix = "scheduler_job/\(entryId)"
        }
        return "[scheduled reminder from \(originPrefix), fired at \(firedAtIso)]\n\n\(bodyText)"
    }

    /// Resolve the caller's DM target, build the wrapped body, and try to
    /// DM it. Called at fire time. Never throws — a DM failure just returns
    /// a `fellBack*` outcome so the caller can spawn a worker as fallback.
    /// Isolated as a `static` helper because it's driven from inside a
    /// `Task.detached` in `fireJob` where actor isolation isn't in scope.
    static func attemptScheduledNotify(
        target: String,
        bodyText: String,
        entryId: String,
        source: JobSource,
        dbPool: DatabasePool,
        logger: Logger
    ) async -> NotifyOutcome {
        let wrapped = Self.wrappedNotifyBody(
            bodyText: bodyText,
            entryId: entryId,
            source: source,
            firedAt: Date()
        )
        let originPrefix: String
        switch source {
        case .calendarEvent: originPrefix = "calendar_event/\(entryId)"
        case .scheduledJob:  originPrefix = "scheduler_job/\(entryId)"
        }

        guard let resolved = await DMTargetResolver.resolve(target, dbPool: dbPool) else {
            let reason: String
            if await SonarPeerLookup.pluginReachable() {
                reason = "no_such_target"
            } else {
                reason = "sonar_offline"
            }
            return .fellBackNotFound(reason: reason)
        }
        if resolved.kind == .selfPeer {
            return .fellBackNotFound(reason: "self_peer")
        }

        // Sender key is a stable synthetic identity for the scheduler.
        // Recipients see the wrapped body's `[scheduled reminder from ...]`
        // preamble; they don't route replies here (there's no live session
        // behind `scheduler:*`). The audit row keeps the attribution.
        let senderKey = "scheduler:\(entryId)"
        let response = await sendResolved(
            target: target,
            resolved: resolved,
            body: wrapped,
            context: "scheduled reminder from \(originPrefix)",
            senderKey: senderKey,
            inReplyToMessageId: nil,
            dbPool: dbPool
        )

        switch response.status {
        case "sent":
            return .sent(messageId: response.messageId ?? "")
        case "not_live":
            return .fellBackNotLive(reason: response.reason ?? "not_live")
        default:
            return .fellBackNotFound(reason: response.reason ?? "not_found")
        }
    }

    // MARK: - Shell Execution

    /// Run a shell command and capture its stdout. Timeout: 5 minutes.
    ///
    /// Completion is driven by `terminationHandler` rather than `waitUntilExit()`. This
    /// function runs on Swift's cooperative thread pool, which has one thread per core;
    /// a blocking wait here holds one of those threads for up to the full 300s timeout.
    /// Sonata's own HTTP server is served from that same pool, so a blocked thread can
    /// starve the very request a child process is waiting on — e.g. a `mem task add` job
    /// whose curl hits localhost:3211. That circular wait is a genuine self-deadlock, and
    /// it presented as NIOAsyncWriter deinit traps on .17 on 2026-07-18.
    ///
    /// Output is drained continuously via `readabilityHandler` instead of a single
    /// `readDataToEndOfFile()` after exit: with nobody reading while the child runs, any
    /// job writing more than the 64KB pipe buffer would block forever waiting to write.
    /// Internal rather than private so the deadlock/large-output regression tests can
    /// drive it directly (see SchedulerShellCommandTests).
    static func runShellCommand(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let state = ShellRunState()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let readEnd = pipe.fileHandleForReading

            @Sendable func finish(_ result: (status: Int32, output: String)) {
                readEnd.readabilityHandler = nil
                if result.status == 0 {
                    continuation.resume(returning: result.output)
                } else {
                    continuation.resume(throwing: SchedulerError.shellFailed(
                        exitCode: result.status,
                        output: result.output
                    ))
                }
            }

            readEnd.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF: every write end is closed.
                    if let result = state.noteEOF() { finish(result) }
                } else {
                    state.append(chunk)
                }
            }

            // Timeout: 5 minutes
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + 300)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }

            process.terminationHandler = { proc in
                timer.cancel()
                let status = proc.terminationStatus
                if let result = state.noteExit(status) {
                    finish(result)
                    return
                }
                // Exited but the pipe has not hit EOF — a surviving grandchild still holds
                // the write end. Grant a short grace for in-flight output, then complete
                // anyway so a background-spawning job can never strand this continuation.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if let result = state.forceFinish(status) { finish(result) }
                }
            }

            do {
                try process.run()
            } catch {
                readEnd.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }

            timer.resume()
        }
    }
}

/// Collects a shell job's output and completes exactly once, when the process has exited
/// *and* its output pipe has reached EOF (or a grace period has elapsed). Both events
/// arrive on arbitrary threads, so all state is lock-protected and the "ready" transition
/// is one-shot — that is what makes double-resume of the continuation impossible.
private final class ShellRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var eofSeen = false
    private var exitStatus: Int32?
    private var completed = false

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func noteEOF() -> (status: Int32, output: String)? {
        lock.lock()
        defer { lock.unlock() }
        eofSeen = true
        return readyLocked()
    }

    func noteExit(_ status: Int32) -> (status: Int32, output: String)? {
        lock.lock()
        defer { lock.unlock() }
        exitStatus = status
        return readyLocked()
    }

    /// Complete on exit alone, ignoring a pipe that never reached EOF.
    func forceFinish(_ status: Int32) -> (status: Int32, output: String)? {
        lock.lock()
        defer { lock.unlock() }
        eofSeen = true
        exitStatus = status
        return readyLocked()
    }

    private func readyLocked() -> (status: Int32, String)? {
        guard eofSeen, let status = exitStatus, !completed else { return nil }
        completed = true
        return (status, String(data: data, encoding: .utf8) ?? "")
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
