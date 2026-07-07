import Foundation
import GRDB
import Logging

/// Manages channel-based task dispatch to worker Claude Code sessions.
///
/// Instead of spawning `claude -p` (headless), this pushes tasks as worker events
/// into the database. The `sonata-channel.ts` MCP channel server (running inside
/// each worker's Claude Code session) polls these events and delivers them to Claude
/// via the channel protocol.
///
/// Flow:
/// 1. TaskDispatcher calls `dispatchToChannel(task:)`
/// 2. This actor creates a workerEvent with the task payload
/// 3. The channel server (TS) polls `/api/worker/events/claim`
/// 4. Claude receives the task as a `<channel source="sonata-channel">` event
/// 5. Claude processes it and calls `complete_task` / `fail_task` via channel tools
/// 6. The channel server calls `/api/worker/events/complete` or `/fail`
actor SonataChannelServer {
    private let dbPool: DatabasePool
    private let logger: Logger

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        var logger = Logger(label: "sonata.channel")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Check if any workers are connected via the channel (registered and not offline).
    func hasConnectedWorkers() async -> Bool {
        do {
            let count = try await dbPool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM workers
                    WHERE status != 'offline'
                    AND lastHeartbeat > ?
                """, arguments: [nowMs() - 30_000])
            }
            return (count ?? 0) > 0
        } catch {
            return false
        }
    }

    /// Find an idle worker registered via channel.
    func findIdleWorker() async -> String? {
        do {
            return try await dbPool.read { db in
                try String.fetchOne(db, sql: """
                    SELECT workerId FROM workers
                    WHERE status = 'idle'
                    AND lastHeartbeat > ?
                    ORDER BY lastHeartbeat DESC
                    LIMIT 1
                """, arguments: [nowMs() - 30_000])
            }
        } catch {
            logger.error("Error finding idle worker: \(error.localizedDescription)")
            return nil
        }
    }

    /// Dispatch a task to an idle worker via the channel.
    ///
    /// Creates a workerEvent that the channel server will pick up on its next poll.
    /// Returns the event ID if dispatched, nil if no idle workers.
    @discardableResult
    func dispatchToChannel(
        taskId: String,
        title: String,
        prompt: String,
        priority: Int = 5
    ) async -> String? {
        guard let workerId = await findIdleWorker() else {
            logger.info("No idle channel workers for task \(taskId)")
            return nil
        }

        let eventId = newUUID()
        let now = nowMs()

        // Build payload with task metadata
        let payload: [String: Any] = [
            "task_id": taskId,
            "title": title,
            "prompt": prompt,
        ]
        let payloadJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            payloadJSON = str
        } else {
            payloadJSON = prompt
        }

        do {
            let claimed = try await dbPool.write { db -> Bool in
                // Claim the worker FIRST, guarded on it still being free.
                // findIdleWorker() ran outside this transaction, so a concurrent
                // dispatch (nightly per-profile bursts) can have taken this worker
                // in between. An unguarded UPDATE overwrites currentEventId,
                // orphaning the open event ('assigned' but unreferenced — its
                // session becomes untracked) and stacking a second prompt onto a
                // busy worker. Seen 2026-07-07 on Scout: CPG p17 orphaned, then
                // MaassWorks p53 + Up Studio p57 stacked and watchdog-killed.
                try db.execute(sql: """
                    UPDATE workers SET status = 'busy', currentEventId = ?
                    WHERE workerId = ?
                      AND status = 'idle'
                      AND (currentEventId IS NULL OR currentEventId = '')
                """, arguments: [eventId, workerId])
                guard db.changesCount == 1 else { return false }

                // Look up worker's sessionId for cycling/resume
                let workerSessionId = try String.fetchOne(db, sql: """
                    SELECT sessionId FROM workers WHERE workerId = ?
                """, arguments: [workerId])

                // Create the worker event (copy sessionId from worker)
                try db.execute(sql: """
                    INSERT INTO workerEvents (id, type, payload, priority, assignedTo, status, createdAt, assignedAt, sessionId)
                    VALUES (?, 'task', ?, ?, ?, 'assigned', ?, ?, ?)
                """, arguments: [eventId, payloadJSON, priority, workerId, now, now, workerSessionId])
                return true
            }

            guard claimed else {
                // Worker was taken between findIdleWorker() and the claim.
                // Treat like "no idle workers" — the task stays pending and the
                // dispatcher retries on its next poll.
                logger.info("Worker \(workerId) no longer idle at claim time for task \(taskId); skipping dispatch")
                return nil
            }

            logger.info("Dispatched task \"\(title)\" to worker \(workerId) via channel (event: \(eventId))")
            return eventId
        } catch {
            logger.error("Failed to dispatch to channel: \(error.localizedDescription)")
            return nil
        }
    }

    /// Check if a channel-dispatched event has completed.
    /// Returns: ("completed", result), ("failed", error), or ("pending", nil)
    func checkEventStatus(eventId: String) async -> (status: String, detail: String?) {
        do {
            let result: (String, String?) = try await dbPool.read { db -> (String, String?) in
                if let row = try Row.fetchOne(db, sql: "SELECT status, result FROM workerEvents WHERE id = ?", arguments: [eventId]) {
                    let s = (row["status"] as? String) ?? "unknown"
                    let d = row["result"] as? String
                    return (s, d)
                }
                return ("unknown", nil)
            }
            return (result.0, result.1)
        } catch {
            return ("error", error.localizedDescription)
        }
    }

    /// Wait for a channel-dispatched event to complete, with timeout.
    func waitForCompletion(eventId: String, timeoutMs: Int = 600_000) async -> (success: Bool, detail: String?) {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        while Date() < deadline {
            let (status, detail) = await checkEventStatus(eventId: eventId)
            switch status {
            case "completed":
                return (true, detail)
            case "failed":
                return (false, detail)
            default:
                // Still pending/assigned — wait and check again
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            }
        }

        return (false, "Timeout after \(timeoutMs)ms")
    }
}
