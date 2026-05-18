import Foundation
import GRDB
import Logging

/// Periodic health monitoring for Sonata services.
///
/// Checks every 60 seconds:
/// - SQLite database accessible
/// - HTTP server responding
/// - Scheduler running
/// - Disk space on data volume
///
/// Tracks SDK session outcomes per label, detects repeated failures,
/// and sends alerts via AgentMail when consecutive failures exceed threshold.
actor HealthMonitor {

    // MARK: - Configuration

    /// How often to run health checks (seconds).
    private let checkInterval: TimeInterval = 60

    /// Minimum free disk space before warning (bytes). 10 GB.
    private let minFreeDiskBytes: UInt64 = 10 * 1024 * 1024 * 1024

    /// Consecutive failures before sending an alert.
    private let alertThreshold: Int = 3

    /// AgentMail configuration for alerts — resolved from DB at send time.
    private var alertFromEmail: String?
    private var alertToEmail: String?

    /// HTTP server URL to check.
    private let serverURL: String

    // MARK: - State

    private let dbPool: DatabasePool
    private let logger: Logger
    private var monitorTask: Task<Void, Never>?
    private var isRunning = false

    /// Consecutive failure counts by check name.
    private var consecutiveFailures: [String: Int] = [:]

    /// Session outcome tracking: label → (successes, failures).
    private var sessionOutcomes: [String: (successes: Int, failures: Int)] = [:]

    /// Last alert sent timestamp by check name (to avoid spamming).
    private var lastAlertSent: [String: Date] = [:]

    /// Minimum interval between alerts for the same check (5 minutes).
    private let alertCooldown: TimeInterval = 300

    /// Fallback interval between supervisor check-event pushes (3 minutes).
    /// Only used if the supervisorConfig singleton row cannot be read.
    private let fallbackSupervisorCheckInterval: TimeInterval = 180

    /// Last time a supervisor check event was pushed.
    private var lastSupervisorCheckPushedAt: Date?

    /// Cached snapshot of the supervisorConfig singleton (refreshed each loop).
    private struct SupervisorSchedule {
        var dayIntervalSec: Int
        var nightIntervalSec: Int
        var nightStartHour: Int
        var nightEndHour: Int
        var enabled: Bool
    }

    /// Weak reference to the scheduler for status checks.
    private let schedulerStatus: (@Sendable () async -> Bool)?

    /// Returns `(target, effective)` for the worker pool. `effective` is the
    /// count of workers in a non-terminal status (i.e. NOT `.offline`).
    /// Optional — when nil, the worker_pool check is skipped (e.g. in test
    /// harnesses that don't boot a WorkerManager).
    private let workerPoolStatus: (@Sendable () async -> (target: Int, effective: Int))?

    /// First time `workerPoolStatus` reported effective < target with no
    /// subsequent recovery. Cleared the moment effective >= target. Used to
    /// distinguish a transient dip (single tick) from a stuck pool (>5 min)
    /// — only the latter triggers the unhealthy CheckResult.
    private var poolUnderTargetSince: Date?

    /// Grace period: how long the pool may run below target before the
    /// `worker_pool` check goes unhealthy. 2026-05-18 incident headline:
    /// "you'll get paged in under 10 min if pool stalls" — combined with
    /// the existing 3-strike alertThreshold and 60s checkInterval this
    /// puts a hard upper bound on time-to-alert. Backstop only; the real
    /// fixes live in WorkerManager.
    private let poolUnderTargetGrace: TimeInterval = 300

    // MARK: - Health Check Result

    struct CheckResult: Sendable {
        let name: String
        let healthy: Bool
        let message: String
        let timestamp: Date
    }

    /// Snapshot of all health checks.
    struct HealthSnapshot: Sendable {
        let checks: [CheckResult]
        let sessionOutcomes: [String: (successes: Int, failures: Int)]
        let overallHealthy: Bool
        let timestamp: Date
    }

    // MARK: - Init

    /// Initialize the health monitor.
    ///
    /// - Parameters:
    ///   - dbPool: Database pool to check.
    ///   - port: HTTP server port to check.
    ///   - schedulerStatus: Closure that returns whether the scheduler is running.
    ///   - logger: Optional logger.
    init(
        dbPool: DatabasePool,
        port: Int = 3212,
        schedulerStatus: (@Sendable () async -> Bool)? = nil,
        workerPoolStatus: (@Sendable () async -> (target: Int, effective: Int))? = nil,
        logger: Logger? = nil
    ) {
        self.dbPool = dbPool
        self.serverURL = "http://127.0.0.1:\(port)/api/ping"
        self.schedulerStatus = schedulerStatus
        self.workerPoolStatus = workerPoolStatus
        var log = logger ?? Logger(label: "sonata.health")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Lifecycle

    /// Start periodic health monitoring.
    func start() {
        guard !isRunning else {
            logger.warning("HealthMonitor already running — ignoring duplicate start()")
            return
        }
        isRunning = true
        logger.info("HealthMonitor started (interval: \(Int(checkInterval))s)")

        monitorTask = Task { [weak self] in
            await self?.monitorLoop()
        }
    }

    /// Stop health monitoring.
    func shutdown() {
        logger.info("HealthMonitor shutting down")
        monitorTask?.cancel()
        monitorTask = nil
        isRunning = false
    }

    /// Record a session outcome for tracking.
    func recordSessionOutcome(label: String, success: Bool) {
        var entry = sessionOutcomes[label] ?? (successes: 0, failures: 0)
        if success {
            entry.successes += 1
        } else {
            entry.failures += 1
        }
        sessionOutcomes[label] = entry

        // Detect repeated failures
        if !success {
            let total = entry.failures
            if total > 0 && total % alertThreshold == 0 {
                logger.warning("Session label '\(label)' has \(total) total failures")
                Task { [weak self] in
                    await self?.sendAlert(
                        check: "session:\(label)",
                        message: "Claude session label '\(label)' has accumulated \(total) failures (vs \(entry.successes) successes)"
                    )
                }
            }
        }
    }

    /// Get a snapshot of current health status (for the /api/status endpoint).
    func snapshot() async -> HealthSnapshot {
        let checks = await runAllChecks()
        let allHealthy = checks.allSatisfy(\.healthy)
        return HealthSnapshot(
            checks: checks,
            sessionOutcomes: sessionOutcomes,
            overallHealthy: allHealthy,
            timestamp: Date()
        )
    }

    // MARK: - Monitor Loop

    private func monitorLoop() async {
        while !Task.isCancelled {
            let checks = await runAllChecks()

            for check in checks {
                if check.healthy {
                    // Reset consecutive failures on success
                    consecutiveFailures[check.name] = 0
                } else {
                    let count = (consecutiveFailures[check.name] ?? 0) + 1
                    consecutiveFailures[check.name] = count

                    logger.warning("Health check '\(check.name)' failed (\(count)x): \(check.message)")

                    if count >= alertThreshold {
                        await sendAlert(
                            check: check.name,
                            message: "Health check '\(check.name)' has failed \(count) consecutive times: \(check.message)"
                        )
                        postDistributedNotification(check: check.name, message: check.message)
                    }
                }
            }

            let failedChecks = checks.filter { !$0.healthy }
            if failedChecks.isEmpty {
                logger.debug("All health checks passed")
            } else {
                logger.warning("\(failedChecks.count) health check(s) failed: \(failedChecks.map(\.name).joined(separator: ", "))")
            }

            // Push a periodic check event to the supervisor, driven by
            // the configurable day/night schedule in supervisorConfig.
            let schedule = await loadSupervisorSchedule()
            if schedule.enabled {
                let interval = currentSupervisorInterval(schedule: schedule)
                if lastSupervisorCheckPushedAt.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
                    await pushSupervisorCheck()
                    lastSupervisorCheckPushedAt = Date()
                }
            }

            do {
                try await Task.sleep(for: .seconds(checkInterval))
            } catch {
                break  // Cancelled
            }
        }
    }

    // MARK: - Supervisor Schedule

    /// Load the supervisorConfig singleton. Falls back to built-in defaults
    /// (day 180s, night 1800s, 22→07, enabled) if the row is missing or
    /// the DB read fails.
    private func loadSupervisorSchedule() async -> SupervisorSchedule {
        do {
            let row: Row? = try dbPool.read { db -> Row? in
                try Row.fetchOne(db, sql: """
                    SELECT dayIntervalSec, nightIntervalSec, nightStartHour,
                           nightEndHour, enabled
                    FROM supervisorConfig WHERE id = 'singleton'
                """)
            }
            if let row {
                return SupervisorSchedule(
                    dayIntervalSec: Int((row["dayIntervalSec"] as Int64?) ?? Int64(fallbackSupervisorCheckInterval)),
                    nightIntervalSec: Int((row["nightIntervalSec"] as Int64?) ?? 1800),
                    nightStartHour: Int((row["nightStartHour"] as Int64?) ?? 22),
                    nightEndHour: Int((row["nightEndHour"] as Int64?) ?? 7),
                    enabled: ((row["enabled"] as Int64?) ?? 1) != 0
                )
            }
        } catch {
            logger.warning("Could not read supervisorConfig (\(error.localizedDescription)) — using defaults")
        }
        return SupervisorSchedule(
            dayIntervalSec: Int(fallbackSupervisorCheckInterval),
            nightIntervalSec: 1800,
            nightStartHour: 22,
            nightEndHour: 7,
            enabled: true
        )
    }

    /// Resolve the effective push interval for the current wall-clock hour.
    /// Day vs night is selected by the configured night window; the window
    /// wraps at midnight when nightStartHour > nightEndHour (e.g. 22→07).
    private func currentSupervisorInterval(schedule: SupervisorSchedule) -> TimeInterval {
        let hour = Calendar.current.component(.hour, from: Date())
        let start = schedule.nightStartHour
        let end = schedule.nightEndHour
        let isNight: Bool
        if start == end {
            isNight = false
        } else if start < end {
            isNight = hour >= start && hour < end
        } else {
            isNight = hour >= start || hour < end
        }
        return TimeInterval(isNight ? schedule.nightIntervalSec : schedule.dayIntervalSec)
    }

    // MARK: - Supervisor Push

    /// Insert a 'check' event into supervisorEvents if the supervisor is running
    /// (lastHeartbeat within the past 60s). Skips if offline — no point queuing
    /// work for a session that isn't listening.
    private func pushSupervisorCheck() async {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let running = (try? await dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM supervisorState WHERE lastHeartbeat >= ?
            """, arguments: [cutoff])
        }) ?? false

        guard running == true else { return }

        do {
            try await dbPool.write { db in
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                try db.execute(sql: """
                    INSERT INTO supervisorEvents (id, type, payload, createdAt)
                    VALUES (?, 'check', '{}', ?)
                """, arguments: [UUID().uuidString.lowercased(), now])
            }
            logger.debug("Pushed supervisor check event")
        } catch {
            logger.warning("Failed to push supervisor check: \(error.localizedDescription)")
        }
    }

    // MARK: - Health Checks

    private func runAllChecks() async -> [CheckResult] {
        let now = Date()
        var results: [CheckResult] = []

        // 1. SQLite database accessible
        results.append(await checkDatabase(at: now))

        // 2. HTTP server responding
        results.append(await checkHTTPServer(at: now))

        // 3. Scheduler running
        results.append(await checkScheduler(at: now))

        // 4. Disk space
        results.append(checkDiskSpace(at: now))

        // 5. Worker pool size (backstop for 2026-05-18 auto-spawn flake).
        // Skipped silently when no provider is configured (test harnesses).
        if let poolResult = await checkWorkerPool(at: now) {
            results.append(poolResult)
        }

        return results
    }

    /// Returns `nil` when no pool-status provider is configured (test mode).
    /// Otherwise: healthy iff effective >= target OR effective < target for
    /// less than `poolUnderTargetGrace`. Unhealthy results feed the existing
    /// consecutive-failure alert path.
    private func checkWorkerPool(at time: Date) async -> CheckResult? {
        guard let provider = workerPoolStatus else { return nil }
        let snapshot = await provider()
        if snapshot.effective >= snapshot.target {
            poolUnderTargetSince = nil
            return CheckResult(
                name: "worker_pool",
                healthy: true,
                message: "OK (\(snapshot.effective)/\(snapshot.target))",
                timestamp: time
            )
        }
        let stuckSince = poolUnderTargetSince ?? time
        poolUnderTargetSince = stuckSince
        let elapsed = time.timeIntervalSince(stuckSince)
        if elapsed < poolUnderTargetGrace {
            return CheckResult(
                name: "worker_pool",
                healthy: true,
                message: "under-target \(Int(elapsed))s grace (\(snapshot.effective)/\(snapshot.target))",
                timestamp: time
            )
        }
        return CheckResult(
            name: "worker_pool",
            healthy: false,
            message: "Pool below target for \(Int(elapsed))s: \(snapshot.effective)/\(snapshot.target)",
            timestamp: time
        )
    }

    /// Test-only knob: prime the stuck-since clock so unit tests can exercise
    /// the past-grace branch without sleeping for 5 minutes of wall time.
    func setPoolUnderTargetSinceForTesting(_ date: Date?) {
        poolUnderTargetSince = date
    }

    /// Test-only invoker for `checkWorkerPool` (private otherwise).
    func runWorkerPoolCheckForTesting(at time: Date = Date()) async -> CheckResult? {
        await checkWorkerPool(at: time)
    }

    /// Check that SQLite is accessible by running a simple query.
    private func checkDatabase(at time: Date) async -> CheckResult {
        do {
            let count = try await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories")
            }
            return CheckResult(
                name: "database",
                healthy: true,
                message: "OK (\(count ?? 0) memories)",
                timestamp: time
            )
        } catch {
            return CheckResult(
                name: "database",
                healthy: false,
                message: "Database error: \(error.localizedDescription)",
                timestamp: time
            )
        }
    }

    /// Check that the HTTP server is responding to /api/ping.
    private func checkHTTPServer(at time: Date) async -> CheckResult {
        guard let url = URL(string: serverURL) else {
            return CheckResult(name: "http_server", healthy: false, message: "Invalid URL", timestamp: time)
        }

        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(from: url)

            guard let http = response as? HTTPURLResponse else {
                return CheckResult(name: "http_server", healthy: false, message: "Non-HTTP response", timestamp: time)
            }

            if http.statusCode == 200 {
                // Verify it's actually our server
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["pong"] as? Bool == true {
                    return CheckResult(name: "http_server", healthy: true, message: "OK", timestamp: time)
                }
                return CheckResult(name: "http_server", healthy: false, message: "Unexpected response body", timestamp: time)
            } else {
                return CheckResult(name: "http_server", healthy: false, message: "HTTP \(http.statusCode)", timestamp: time)
            }
        } catch {
            return CheckResult(name: "http_server", healthy: false, message: "Connection failed: \(error.localizedDescription)", timestamp: time)
        }
    }

    /// Check that the scheduler actor is running.
    private func checkScheduler(at time: Date) async -> CheckResult {
        if let statusFn = schedulerStatus {
            let running = await statusFn()
            return CheckResult(
                name: "scheduler",
                healthy: running,
                message: running ? "OK" : "Scheduler not running",
                timestamp: time
            )
        }
        // No status function provided — can't check, assume OK
        return CheckResult(name: "scheduler", healthy: true, message: "OK (no status hook)", timestamp: time)
    }

    /// Check available disk space on the data volume.
    private func checkDiskSpace(at time: Date) -> CheckResult {
        let dataDir = NSHomeDirectory() + "/.sonata"
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: dataDir)
            guard let freeSpace = attrs[.systemFreeSize] as? UInt64 else {
                return CheckResult(name: "disk_space", healthy: false, message: "Could not read free space", timestamp: time)
            }

            let freeGB = Double(freeSpace) / (1024 * 1024 * 1024)
            let healthy = freeSpace >= minFreeDiskBytes
            let message = healthy
                ? String(format: "OK (%.1f GB free)", freeGB)
                : String(format: "Low disk space: %.1f GB free (< 10 GB)", freeGB)

            return CheckResult(name: "disk_space", healthy: healthy, message: message, timestamp: time)
        } catch {
            return CheckResult(name: "disk_space", healthy: false, message: "Error: \(error.localizedDescription)", timestamp: time)
        }
    }

    // MARK: - Alerts

    /// Resolve alert email addresses from the first enabled inbox in the DB.
    private func resolveAlertEmails() async {
        if alertFromEmail != nil { return }
        do {
            let inbox: (address: String, role: String)? = try await dbPool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT address, role FROM emailInboxes
                    WHERE enabled = 1 ORDER BY createdAt ASC LIMIT 1
                """).map { (address: $0["address"] as String, role: $0["role"] as String) }
            }
            if let inbox {
                alertFromEmail = inbox.address
                // Alert recipient: look for owner_email in core config, fall back to sender
                let ownerEmail: String? = try? await dbPool.read { db in
                    try String.fetchOne(db, sql: "SELECT content FROM coreBlocks WHERE key = 'owner_email' AND active = 1")
                }
                alertToEmail = ownerEmail ?? inbox.address
                logger.info("Health alerts: from=\(inbox.address), to=\(alertToEmail ?? inbox.address)")
            }
        } catch {
            logger.warning("Could not resolve alert emails: \(error)")
        }
    }

    /// Send an alert email via AgentMail HTTP API.
    private func sendAlert(check: String, message: String) async {
        // Cooldown check — don't spam alerts
        if let lastSent = lastAlertSent[check],
           Date().timeIntervalSince(lastSent) < alertCooldown {
            return
        }
        lastAlertSent[check] = Date()

        logger.error("ALERT [\(check)]: \(message)")

        // Resolve sender/recipient from DB on first use
        await resolveAlertEmails()
        guard let fromEmail = alertFromEmail else {
            logger.warning("No email inbox configured — alert logged only")
            return
        }

        // Send via AgentMail API
        guard let url = URL(string: "https://api.agentmail.to/v0/inboxes/\(fromEmail)/messages") else {
            logger.error("Failed to build AgentMail URL")
            return
        }

        let emailBody: [String: Any] = [
            "to": alertToEmail ?? fromEmail,
            "subject": "🚨 Sonata Health Alert: \(check)",
            "body": """
            Sonata Health Monitor Alert

            Check: \(check)
            Time: \(ISO8601DateFormatter().string(from: Date()))

            \(message)

            ---
            Sent by Sonata HealthMonitor
            """
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: emailBody) else {
            logger.error("Failed to serialize alert email")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode < 300 {
                logger.info("Alert email sent for check '\(check)'")
            } else {
                logger.warning("Alert email may have failed for check '\(check)'")
            }
        } catch {
            logger.error("Failed to send alert email: \(error)")
        }
    }

    /// Post a DistributedNotification for other local processes to observe.
    private nonisolated func postDistributedNotification(check: String, message: String) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("sonata.healthAlert"),
            object: check,
            userInfo: ["check": check, "message": message],
            deliverImmediately: true
        )
    }
}
