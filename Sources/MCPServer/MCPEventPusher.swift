import Foundation
import GRDB
import Logging

actor MCPEventPusher {
    private let dbPool: DatabasePool
    private let registry: MCPSessionRegistry
    private let logger: Logger
    private var knownWorkerEventIds: Set<String> = []
    private var knownSupervisorEventIds: Set<String> = []
    private var task: Task<Void, Never>?
    private let pollInterval: TimeInterval = 1.0

    init(dbPool: DatabasePool, registry: MCPSessionRegistry, logger: Logger) {
        self.dbPool = dbPool
        self.registry = registry
        self.logger = logger
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 1.0) * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        // In the legacy bridge model, workers polled `worker_event_claim`
        // to move events from pending → assigned. The new in-app model
        // inverts this: workers idle until pushed. So Sonata must do the
        // assignment itself for any idle worker with SSE attached, then
        // push the notification.
        await assignPendingToIdleWorkers()
        await pushPendingWorkerEvents()
        await pushPendingSupervisorEvents()
    }

    /// Atomically claim pending events for any worker that has SSE attached,
    /// is currently idle in both the registry (no inFlightEventId) and the
    /// DB (status='idle', currentEventId IS NULL), and whose sessionLabel
    /// matches `sona-worker-N`. Mirrors the `worker_event_claim` action's
    /// state-machine transitions but runs from the server side.
    private func assignPendingToIdleWorkers() async {
        let snapshots = await registry.snapshot()
        let candidates = snapshots.filter {
            $0.role == .worker && $0.hasSSE && $0.inFlightEventId == nil
        }
        if candidates.isEmpty { return }

        for snap in candidates {
            do {
                try await dbPool.write { db in
                    let workerRow = try Row.fetchOne(db, sql: """
                        SELECT status, currentEventId, sessionLabel
                        FROM workers WHERE workerId = ?
                    """, arguments: [snap.sessionKey])
                    guard let workerRow else { return }
                    let status = workerRow["status"] as? String ?? ""
                    if status == "busy" || status == "draining" { return }
                    if (workerRow["currentEventId"] as? String) != nil { return }
                    let label = workerRow["sessionLabel"] as? String ?? ""
                    let isValidLabel = label == "supervisor"
                        || label.range(of: #"^sona-worker-\d+$"#,
                                       options: .regularExpression) != nil
                    if !isValidLabel { return }

                    guard let evtId = try String.fetchOne(db, sql: """
                        SELECT id FROM workerEvents
                        WHERE status = 'pending'
                        ORDER BY priority DESC, createdAt ASC LIMIT 1
                    """) else { return }

                    let now = nowMs()
                    let workerSessionId = try String.fetchOne(db, sql:
                        "SELECT sessionId FROM workers WHERE workerId = ?",
                        arguments: [snap.sessionKey])
                    try db.execute(sql: """
                        UPDATE workerEvents
                        SET assignedTo = ?, status = 'assigned',
                            assignedAt = ?, sessionId = ?
                        WHERE id = ? AND status = 'pending'
                    """, arguments: [snap.sessionKey, now, workerSessionId, evtId])
                    try db.execute(sql: """
                        UPDATE workers SET status = 'busy',
                            currentEventId = ?, lastHeartbeat = ?
                        WHERE workerId = ?
                    """, arguments: [evtId, now, snap.sessionKey])
                }
            } catch {
                logger.warning("EventPusher auto-assign failed for \(snap.sessionKey): \(error)")
            }
        }
    }

    private struct PendingWorkerEvent: Sendable {
        let id: String
        let assignedTo: String
        let type: String
        let payload: String
        let priority: Int
        let createdAt: Int64
    }

    private func pushPendingWorkerEvents() async {
        let rows: [PendingWorkerEvent]
        do {
            rows = try await dbPool.read { db -> [PendingWorkerEvent] in
                try Row.fetchAll(db, sql: """
                    SELECT id, assignedTo, type, payload, priority, createdAt
                    FROM workerEvents
                    WHERE status = 'assigned'
                    ORDER BY priority DESC, createdAt ASC
                    LIMIT 50
                """).compactMap { row in
                    guard let assignedTo = row["assignedTo"] as? String,
                          !assignedTo.isEmpty else { return nil }
                    return PendingWorkerEvent(
                        id: row["id"] as? String ?? "",
                        assignedTo: assignedTo,
                        type: row["type"] as? String ?? "",
                        payload: row["payload"] as? String ?? "{}",
                        priority: row["priority"] as? Int ?? 5,
                        createdAt: row["createdAt"] as? Int64 ?? 0
                    )
                }
            }
        } catch {
            logger.warning("EventPusher worker query failed: \(error)")
            return
        }

        for evt in rows where !knownWorkerEventIds.contains(evt.id) {
            knownWorkerEventIds.insert(evt.id)
            let content = renderWorkerEventContent(payload: evt.payload)
            let delivered = await MCPNotificationDispatcher.shared.pushWorkerEvent(
                sessionKey: evt.assignedTo,
                eventId: evt.id,
                eventType: evt.type,
                priority: evt.priority,
                createdAt: evt.createdAt,
                content: content
            )
            if !delivered {
                knownWorkerEventIds.remove(evt.id)
            }
        }
    }

    private func renderWorkerEventContent(payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return payload
        }
        if let str = obj as? String { return str }
        if let dict = obj as? [String: Any] {
            if let s = dict["summary"] as? String { return s }
            if let s = dict["prompt"] as? String { return s }
            if let s = dict["body"] as? String { return s }
        }
        return payload
    }

    private struct PendingSupervisorEvent: Sendable {
        let id: String
        let type: String
        let payload: String
    }

    private func pushPendingSupervisorEvents() async {
        let staleCutoff = nowMs() - 600_000
        let rows: [PendingSupervisorEvent]
        do {
            rows = try await dbPool.read { db -> [PendingSupervisorEvent] in
                try Row.fetchAll(db, sql: """
                    SELECT id, type, payload FROM supervisorEvents
                    WHERE claimedAt IS NULL AND createdAt >= ?
                    ORDER BY createdAt ASC LIMIT 10
                """, arguments: [staleCutoff]).map { row in
                    PendingSupervisorEvent(
                        id: row["id"] as? String ?? "",
                        type: row["type"] as? String ?? "check",
                        payload: row["payload"] as? String ?? "{}"
                    )
                }
            }
        } catch {
            logger.warning("EventPusher supervisor query failed: \(error)")
            return
        }

        for evt in rows where !knownSupervisorEventIds.contains(evt.id) {
            knownSupervisorEventIds.insert(evt.id)
            let content = renderSupervisorEventContent(
                type: evt.type, payload: evt.payload)
            let delivered = await MCPNotificationDispatcher.shared
                .pushSupervisorEvent(
                    eventId: evt.id, eventType: evt.type, content: content)
            if delivered {
                do {
                    try await dbPool.write { db in
                        try db.execute(sql:
                            "UPDATE supervisorEvents SET claimedAt = ? WHERE id = ?",
                            arguments: [nowMs(), evt.id])
                    }
                } catch {
                    logger.warning("EventPusher supervisor claim-mark failed: \(error)")
                }
            } else {
                knownSupervisorEventIds.remove(evt.id)
            }
        }
    }

    private func renderSupervisorEventContent(type: String, payload: String) -> String {
        switch type {
        case "check":
            return "Periodic health check. Run your checklist and report findings."
        case "query":
            if let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["message"] as? String {
                return msg
            }
            return payload
        default:
            return payload
        }
    }
}
