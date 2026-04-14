import Foundation
import GRDB
import Logging

/// Watches the `backgroundJobs` table for pending jobs and executes them
/// by spawning Claude sessions via `ClaudeProcessManager`.
///
/// Features:
/// - Claims jobs atomically (pending → running)
/// - Dedup: only one pending/running job per name at a time
/// - Timeout: auto-fails jobs running longer than 15 minutes
/// - Cleanup: deletes completed/failed jobs older than 7 days
actor BackgroundJobRunner {

    // MARK: - Configuration

    /// How often to poll for new pending jobs (seconds).
    private let pollInterval: TimeInterval = 10

    /// Maximum job runtime before auto-fail (seconds).
    private let jobTimeoutSeconds: TimeInterval = 15 * 60

    /// Retention period for completed/failed jobs (seconds).
    private let cleanupRetentionSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// How often to run cleanup (seconds).
    private let cleanupInterval: TimeInterval = 60 * 60  // hourly

    // MARK: - State

    private let dbPool: DatabasePool
    private let logger: Logger
    private var pollTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var isRunning = false

    /// Track running job IDs to enforce one execution at a time per name.
    private var runningJobIds: Set<String> = []

    // MARK: - Init

    init(dbPool: DatabasePool, logger: Logger? = nil) {
        self.dbPool = dbPool
        var log = logger ?? Logger(label: "sonata.background-jobs")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Lifecycle

    /// Start polling for pending background jobs.
    func start() {
        guard !isRunning else {
            logger.warning("BackgroundJobRunner already running — ignoring duplicate start()")
            return
        }
        isRunning = true
        logger.info("BackgroundJobRunner started")

        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
        cleanupTask = Task { [weak self] in
            await self?.cleanupLoop()
        }
    }

    /// Gracefully shut down.
    func shutdown() {
        logger.info("BackgroundJobRunner shutting down")
        pollTask?.cancel()
        cleanupTask?.cancel()
        pollTask = nil
        cleanupTask = nil
        isRunning = false
    }

    /// Returns the set of currently running job IDs.
    func runningJobs() -> Set<String> {
        runningJobIds
    }

    // MARK: - Poll Loop

    /// Main loop: poll for pending jobs, claim and execute them.
    private func pollLoop() async {
        while !Task.isCancelled {
            // 1. Timeout stale running jobs
            await timeoutStaleJobs()

            // 2. Find and claim pending jobs
            let jobs = await claimPendingJobs()

            // 3. Execute each claimed job
            for job in jobs {
                let dbPool = self.dbPool
                let logger = self.logger

                // Track the running job
                runningJobIds.insert(job.id)

                // Execute in a detached task so we can continue polling
                let jobId = job.id
                Task.detached { [weak self] in
                    await Self.executeJob(job, dbPool: dbPool, logger: logger)
                    await self?.jobCompleted(jobId)
                }
            }

            // Sleep until next poll
            do {
                try await Task.sleep(for: .seconds(pollInterval))
            } catch {
                break  // Cancelled
            }
        }
    }

    /// Remove job from running set after completion.
    private func jobCompleted(_ jobId: String) {
        runningJobIds.remove(jobId)
    }

    // MARK: - Claim Jobs

    /// Find pending jobs that aren't duplicates, and atomically claim them.
    private func claimPendingJobs() async -> [BackgroundJobRow] {
        do {
            return try await dbPool.write { db -> [BackgroundJobRow] in
                let now = nowMs()

                // Find pending jobs where no other pending/running job with same name exists
                // (dedup: only one pending/running job per name at a time)
                let rows = try BackgroundJobRow.fetchAll(db, sql: """
                    SELECT * FROM backgroundJobs
                    WHERE status = 'pending'
                    AND name NOT IN (
                        SELECT name FROM backgroundJobs
                        WHERE status = 'running'
                    )
                    ORDER BY createdAt ASC
                    LIMIT 5
                """)

                // Deduplicate by name within this batch
                var seen: Set<String> = []
                var claimed: [BackgroundJobRow] = []

                for var row in rows {
                    guard !seen.contains(row.name) else { continue }
                    seen.insert(row.name)

                    // Claim: pending → running
                    try db.execute(
                        sql: "UPDATE backgroundJobs SET status = 'running', startedAt = ? WHERE id = ? AND status = 'pending'",
                        arguments: [now, row.id]
                    )
                    row.status = "running"
                    row.startedAt = now
                    claimed.append(row)
                }

                return claimed
            }
        } catch {
            logger.error("Failed to claim pending jobs: \(error)")
            return []
        }
    }

    // MARK: - Execute Job

    /// Execute a single background job by spawning a Claude session.
    private static func executeJob(
        _ job: BackgroundJobRow,
        dbPool: DatabasePool,
        logger: Logger
    ) async {
        logger.info("Executing background job '\(job.name)' (id: \(job.id))")

        let startTime = ContinuousClock.now

        do {
            let result = try await ClaudeProcessManager.run(
                prompt: job.prompt,
                model: job.model,
                maxTurns: job.maxTurns ?? 15,
                label: "bg:\(job.name)",
                timeoutMs: 15 * 60 * 1000  // 15 minute timeout
            )

            let elapsed = startTime.duration(to: .now)
            let durationSec = Int(elapsed.components.seconds)

            if result.isError {
                // Claude session returned an error
                logger.warning("Background job '\(job.name)' failed: \(result.errorMessage ?? "unknown")")
                await markFailed(
                    jobId: job.id,
                    error: result.errorMessage ?? "Claude session error",
                    dbPool: dbPool,
                    logger: logger
                )
            } else {
                // Success
                let summary = "Completed in \(durationSec)s, \(result.numTurns) turns, $\(String(format: "%.4f", result.totalCost))"
                logger.info("Background job '\(job.name)' completed: \(summary)")
                await markCompleted(
                    jobId: job.id,
                    result: summary,
                    dbPool: dbPool,
                    logger: logger
                )
            }
        } catch {
            logger.error("Background job '\(job.name)' threw: \(error)")
            await markFailed(
                jobId: job.id,
                error: String(describing: error),
                dbPool: dbPool,
                logger: logger
            )
        }
    }

    // MARK: - Status Updates

    private static func markCompleted(
        jobId: String,
        result: String,
        dbPool: DatabasePool,
        logger: Logger
    ) async {
        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE backgroundJobs SET status = 'completed', result = ?, completedAt = ? WHERE id = ?",
                    arguments: [result, now, jobId]
                )
            }
        } catch {
            logger.error("Failed to mark job \(jobId) completed: \(error)")
        }
    }

    private static func markFailed(
        jobId: String,
        error: String,
        dbPool: DatabasePool,
        logger: Logger
    ) async {
        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE backgroundJobs SET status = 'failed', error = ?, completedAt = ? WHERE id = ?",
                    arguments: [error, now, jobId]
                )
            }
        } catch {
            logger.error("Failed to mark job \(jobId) failed: \(error)")
        }
    }

    // MARK: - Timeout Stale Jobs

    /// Auto-fail any running jobs that have exceeded the timeout.
    private func timeoutStaleJobs() async {
        let cutoff = nowMs() - Int64(jobTimeoutSeconds * 1000)
        let now = nowMs()

        do {
            let timedOut = try await dbPool.write { db -> Int in
                let count = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM backgroundJobs WHERE status = 'running' AND startedAt < ?",
                    arguments: [cutoff]
                ) ?? 0

                if count > 0 {
                    try db.execute(
                        sql: """
                        UPDATE backgroundJobs
                        SET status = 'failed', error = 'Timed out after 15 minutes', completedAt = ?
                        WHERE status = 'running' AND startedAt < ?
                        """,
                        arguments: [now, cutoff]
                    )
                }
                return count
            }

            if timedOut > 0 {
                logger.warning("Timed out \(timedOut) stale background job(s)")
            }
        } catch {
            logger.error("Failed to timeout stale jobs: \(error)")
        }
    }

    // MARK: - Cleanup Loop

    /// Periodically delete old completed/failed jobs.
    private func cleanupLoop() async {
        while !Task.isCancelled {
            // Sleep first, then clean
            do {
                try await Task.sleep(for: .seconds(cleanupInterval))
            } catch {
                break  // Cancelled
            }

            let cutoff = nowMs() - Int64(cleanupRetentionSeconds * 1000)

            do {
                let deleted = try await dbPool.write { db -> Int in
                    let count = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM backgroundJobs WHERE status IN ('completed', 'failed') AND completedAt < ?",
                        arguments: [cutoff]
                    ) ?? 0

                    if count > 0 {
                        try db.execute(
                            sql: "DELETE FROM backgroundJobs WHERE status IN ('completed', 'failed') AND completedAt < ?",
                            arguments: [cutoff]
                        )
                    }
                    return count
                }

                if deleted > 0 {
                    logger.info("Cleaned up \(deleted) old background job(s)")
                }
            } catch {
                logger.error("Failed to clean up old jobs: \(error)")
            }
        }
    }
}
