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
        // Deliver notification-type events FIRST, before regular assignment.
        // Otherwise an incoming DM would go through the assign path, pin a
        // worker to 'busy' with a currentEventId, and stay stuck (workers
        // don't call complete_event on notifications). See `notificationTypes`.
        await pushPendingNotifications()
        await assignPendingToIdleWorkers()
        await pushPendingWorkerEvents()
        await pushPendingSupervisorEvents()
    }

    /// workerEvents.type values that are notifications, not work items.
    /// These get pushed to a live worker's SSE stream and immediately
    /// marked completed — they do NOT go through the assign lifecycle
    /// that pins worker.status='busy' and sets currentEventId. Adding a
    /// new notification type here is a one-liner; do not forget to also
    /// exclude it from `assignPendingToIdleWorkers`'s pending pick query
    /// (matched via the same set).
    private static let notificationTypes: Set<String> = ["sonar_dm"]

    /// Find live workers with no assigned event and hand them pending work.
    /// "Live" = has an SSE stream in MCPConnections. "Idle" = DB says
    /// status='idle', currentEventId IS NULL, sessionLabel is a valid pool
    /// slot.
    private func assignPendingToIdleWorkers() async {
        // Query the DB for eligible workers, cross-check hasLive.
        let candidates: [String] = (try? await dbPool.read { db -> [String] in
            try String.fetchAll(db, sql: """
                SELECT workerId FROM workers
                WHERE status = 'idle' AND currentEventId IS NULL
                  AND (sessionLabel = 'supervisor'
                       OR sessionLabel GLOB 'sona-worker-*')
            """)
        }) ?? []
        if candidates.isEmpty { return }

        for workerId in candidates {
            guard await MCPConnections.shared.hasLive(workerId) else { continue }
            do {
                try await dbPool.write { db in
                    // Re-verify state (may have changed since read).
                    let workerRow = try Row.fetchOne(db, sql: """
                        SELECT status, currentEventId FROM workers WHERE workerId = ?
                    """, arguments: [workerId])
                    guard let workerRow else { return }
                    let status = workerRow["status"] as? String ?? ""
                    if status != "idle" { return }
                    if (workerRow["currentEventId"] as? String) != nil { return }

                    // Skip notification-type pending events — they're delivered
                    // by pushPendingNotifications and must NOT pin a worker to
                    // 'busy'. Bind the notification types via SQL parameters
                    // so the set stays authoritative in one place.
                    let notifiablePlaceholders = MCPEventPusher.notificationTypes
                        .map { _ in "?" }.joined(separator: ",")
                    var args: [DatabaseValueConvertible] = []
                    args.append(contentsOf: MCPEventPusher.notificationTypes.map { $0 as DatabaseValueConvertible })
                    guard let evtId = try String.fetchOne(db, sql: """
                        SELECT id FROM workerEvents
                        WHERE status = 'pending'
                          AND type NOT IN (\(notifiablePlaceholders))
                        ORDER BY priority DESC, createdAt ASC LIMIT 1
                    """, arguments: StatementArguments(args)) else { return }

                    let now = nowMs()
                    let workerSessionId = try String.fetchOne(db, sql:
                        "SELECT sessionId FROM workers WHERE workerId = ?",
                        arguments: [workerId])
                    try db.execute(sql: """
                        UPDATE workerEvents
                        SET assignedTo = ?, status = 'assigned',
                            assignedAt = ?, sessionId = ?
                        WHERE id = ? AND status = 'pending'
                    """, arguments: [workerId, now, workerSessionId, evtId])
                    try db.execute(sql: """
                        UPDATE workers SET status = 'busy',
                            currentEventId = ?, lastHeartbeat = ?
                        WHERE workerId = ?
                    """, arguments: [evtId, now, workerId])
                }
            } catch {
                logger.warning("EventPusher auto-assign failed for \(workerId): \(error)")
            }
        }
    }

    /// Notification-type events (see `notificationTypes`): SSE push to a
    /// live worker + immediate mark-completed. NO worker.status='busy',
    /// NO currentEventId pin. Rationale: notifications are fire-and-forget;
    /// receivers don't call complete_event on them (see AFK/DM patterns),
    /// so if they went through the normal assign lifecycle they'd sit
    /// `assigned` forever and pin the worker to `busy`.
    private struct PendingNotification: Sendable {
        let id: String
        let type: String
        let payload: String
        let priority: Int
        let createdAt: Int64
    }

    private func pushPendingNotifications() async {
        let notifs: [PendingNotification]
        do {
            let placeholders = MCPEventPusher.notificationTypes
                .map { _ in "?" }.joined(separator: ",")
            let args: [DatabaseValueConvertible] = MCPEventPusher.notificationTypes
                .map { $0 as DatabaseValueConvertible }
            notifs = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, type, payload, priority, createdAt
                    FROM workerEvents
                    WHERE status = 'pending' AND type IN (\(placeholders))
                    ORDER BY priority DESC, createdAt ASC
                    LIMIT 20
                """, arguments: StatementArguments(args)).map { row in
                    PendingNotification(
                        id: row["id"] as? String ?? "",
                        type: row["type"] as? String ?? "",
                        payload: row["payload"] as? String ?? "{}",
                        priority: row["priority"] as? Int ?? 5,
                        createdAt: row["createdAt"] as? Int64 ?? 0
                    )
                }
            }
        } catch {
            logger.warning("EventPusher notification query failed: \(error)")
            return
        }

        guard !notifs.isEmpty else { return }

        // Live worker sessionKeys (workerId is the MCP session key — see
        // MCPHTTPRouter's /mcp/:sessionKey). Skip 'supervisor'; DMs to
        // supervisor are a separate path.
        let liveKeys = await MCPConnections.shared.liveSessionKeys()
        let workerKeys: [String] = liveKeys.filter { $0 != "supervisor" }
        guard !workerKeys.isEmpty else {
            // No live workers to deliver to — leave events pending; next tick
            // will retry once a worker attaches its SSE stream.
            return
        }

        for notif in notifs {
            let content = renderWorkerEventContent(payload: notif.payload)
            var delivered = false
            for key in workerKeys {
                if await MCPNotificationDispatcher.shared.pushWorkerEvent(
                    sessionKey: key,
                    eventId: notif.id,
                    eventType: notif.type,
                    priority: notif.priority,
                    createdAt: notif.createdAt,
                    content: content
                ) {
                    delivered = true
                    break
                }
            }
            if delivered {
                let now = nowMs()
                do {
                    try await dbPool.write { db in
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET status = 'completed', completedAt = ?,
                                result = 'notification delivered via SSE'
                            WHERE id = ? AND status = 'pending'
                        """, arguments: [now, notif.id])
                    }
                } catch {
                    logger.warning("EventPusher: failed to mark notification completed for \(notif.id): \(error)")
                }
            }
            // If not delivered (no live worker SSE), leave as pending —
            // next tick tries again once a worker attaches.
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
                    guard let assignedTo = row["assignedTo"] as? String, !assignedTo.isEmpty else { return nil }
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
            // In-flight state lives only in the DB (workers.currentEventId) —
            // there is no in-memory shadow to update.
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
            let content = renderSupervisorEventContent(type: evt.type, payload: evt.payload)
            let delivered = await MCPNotificationDispatcher.shared
                .pushSupervisorEvent(eventId: evt.id, eventType: evt.type, content: content)
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
