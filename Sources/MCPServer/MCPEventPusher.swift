import Foundation
import GRDB
import Logging

actor MCPEventPusher {
    private let dbPool: DatabasePool
    private let logger: Logger
    private var knownWorkerEventIds: Set<String> = []
    private var knownSupervisorEventIds: Set<String> = []
    private var task: Task<Void, Never>?
    private let pollInterval: TimeInterval = 1.0

    init(dbPool: DatabasePool, logger: Logger) {
        self.dbPool = dbPool
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
        await pushPendingWorkerEvents()
        await pushPendingSupervisorEvents()
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
