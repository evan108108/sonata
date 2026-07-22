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
    ///
    /// NOTE (2026-07-09): sonar_dm was removed from this set. It was
    /// causing initial peer DMs to fan out to every non-supervisor SSE
    /// session and get consumed by whichever interactive session (e.g.
    /// Adaptengine) reacted first, bypassing the worker pool entirely.
    /// The MCPInstructionsBody SONAR_DM section already tells receivers
    /// to call complete_event, so treating sonar_dm as a proper work
    /// item (assigned to a specific worker, worker.status='busy',
    /// eventually completed by the worker) matches the documented
    /// contract and keeps peer DMs off arbitrary sessions.
    ///
    /// 2026-07-22: memory_request added. Sidecar-owned event, routed by
    /// `SidecarRegistry.assignee(forEventType:)` to a specific sessionKey
    /// (not fanned out). Delivered by `pushPendingWorkerEvents` on the
    /// assigned path and auto-completed there — the sidecar's dispatcher
    /// hands the payload to a headless internal agent that has no MCP tool
    /// surface for `worker_event_complete`, so the completion has to
    /// happen server-side. Fire-and-forget by design; a missed hint is
    /// the acceptable failure.
    static let notificationTypes: Set<String> = ["memory_request"]

    /// Types that are always owned by a sidecar, by contract, regardless of
    /// whether `SidecarRegistry.register` has run yet. Belt for the boot race:
    /// `MCPEventPusher.start` fires ~350 lines before `bootSidecars` in
    /// `SonataApp`, and that ordering is intentional (worker-pool slots claim
    /// first). During the gap, `SidecarRegistry.ownsEventType` answers false
    /// for types that the sidecar is about to claim, so a memory_request that
    /// arrived in that window would fan out to a random pool worker. Adding
    /// the type here closes the race without disturbing boot ordering.
    ///
    /// Keep in sync with the sidecar registrations in `bootSidecars`. A stale
    /// entry here just means "we refuse to fan-out a type nobody claims" —
    /// harmless; a missing entry means the boot-race leak comes back.
    private static let sidecarOwnedFallbacks: Set<String> = ["memory_request"]

    /// Find live workers with no assigned event and hand them pending work.
    /// "Live" = has an SSE stream in MCPConnections. "Idle" = DB says
    /// status='idle', currentEventId IS NULL, sessionLabel is a valid pool
    /// slot (`poolSlotSQLPredicate`).
    ///
    /// The predicate used to also admit `sessionLabel = 'supervisor'`. That was
    /// dead: the supervisor keeps its state in `supervisorState` and has never
    /// had a `workers` row, so the branch matched nothing while implying the
    /// supervisor was a dispatch target.
    private func assignPendingToIdleWorkers() async {
        // Query the DB for eligible workers, cross-check hasLive.
        let candidates: [String] = (try? await dbPool.read { db -> [String] in
            try String.fetchAll(db, sql: """
                SELECT workerId FROM workers
                WHERE status = 'idle' AND currentEventId IS NULL
                  AND \(poolSlotSQLPredicate)
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
            // Built out here, not inside the closure: `[any DatabaseValueConvertible]`
            // is not Sendable and capturing it in the @Sendable read closure is an
            // error under the Swift 6 language mode. StatementArguments is Sendable.
            let args = StatementArguments(
                MCPEventPusher.notificationTypes.map(\.databaseValue)
            )
            notifs = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, type, payload, priority, createdAt
                    FROM workerEvents
                    WHERE status = 'pending' AND type IN (\(placeholders))
                    ORDER BY priority DESC, createdAt ASC
                    LIMIT 20
                """, arguments: args).map { row in
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

        // Split off sidecar-owned notifs. These landed as `pending` only
        // because they raced the sidecar's registration at boot, or because
        // the sidecar was never registered on this launch. In either case,
        // fan-out delivery is wrong: dropping the raw JSON blob on a random
        // pool worker's SSE (as this function historically did for sonar_dm
        // broadcasts) delivers a message meant for the sidecar's dispatcher
        // to an uninstructed worker, which is exactly the "SILENT." + 40-Opus-
        // sessions-of-noise failure mode the 2026-07-22 redesign closed. Mark
        // these failed here so the pending queue clears; if a sidecar spawns
        // and starts owning the type moments later, new events will route to
        // it via the assigned path — the failed ones are stale by then anyway.
        var orphanedSidecar: [PendingNotification] = []
        var fanOut: [PendingNotification] = []
        for notif in notifs {
            let owned = SidecarRegistry.shared.ownsEventType(notif.type)
                || MCPEventPusher.sidecarOwnedFallbacks.contains(notif.type)
            if owned {
                orphanedSidecar.append(notif)
            } else {
                fanOut.append(notif)
            }
        }
        for notif in orphanedSidecar {
            let now = nowMs()
            do {
                try await dbPool.write { db in
                    try db.execute(sql: """
                        UPDATE workerEvents
                        SET status = 'failed', completedAt = ?,
                            result = 'sidecar-owned notification with no live sessionKey; refusing pool fan-out'
                        WHERE id = ? AND status = 'pending'
                    """, arguments: [now, notif.id])
                }
                logger.warning("EventPusher: dropped orphan sidecar-owned notification \(notif.id) (type \(notif.type))")
            } catch {
                logger.warning("EventPusher: failed to mark orphan notification \(notif.id) as failed: \(error)")
            }
        }
        guard !fanOut.isEmpty else { return }

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

        for notif in fanOut {
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

            // In-process sidecar events don't push over SSE — dispatch to
            // the registered Swift handler directly, then auto-complete on
            // return (or auto-fail on throw). The `inproc-` prefix is set
            // by `SidecarInProcessKey`; nothing else in Sonata publishes
            // a session key with that shape, so it's an unambiguous signal.
            if SidecarInProcessKey.isInProcess(evt.assignedTo) {
                await dispatchInProcess(event: evt)
                continue
            }

            let baseContent = renderWorkerEventContent(payload: evt.payload)
            // Inline the current handling contract for cache-busting event
            // types. MCPInstructionsBody is only sent at MCP handshake; a
            // worker session that was --resumed from before a semantic change
            // (e.g. sonar_dm going from fire-and-forget notification to
            // proper work item on 2026-07-09) still has prior-turn context
            // baked in that overrides fresh handshake instructions. Inlining
            // the rules per-event with the actual ids/values makes cached
            // context unable to win.
            let content: String = {
                if let extra = inlineHandlingReminder(
                    for: evt.type, eventId: evt.id, payloadJSON: evt.payload
                ) {
                    return baseContent + "\n\n" + extra
                }
                return baseContent
            }()
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
                continue
            }
            // Notification-type events auto-complete on push. Their recipients
            // have no completion path — either by design (memory_request's
            // sub-agent dispatcher can't reach worker_event_complete because
            // sonata-bridge MCP tools don't load into internal agents) or by
            // convention (fire-and-forget notifications). Left as `assigned`
            // they'd sit forever and pretend to be work.
            if MCPEventPusher.notificationTypes.contains(evt.type) {
                do {
                    let now = nowMs()
                    try await dbPool.write { db in
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET status = 'completed', completedAt = ?,
                                result = 'notification delivered via SSE'
                            WHERE id = ? AND status = 'assigned'
                        """, arguments: [now, evt.id])
                    }
                } catch {
                    logger.warning("EventPusher: failed to auto-complete notification \(evt.id): \(error)")
                }
            }
            // In-flight state lives only in the DB (workers.currentEventId) —
            // there is no in-memory shadow to update.
        }
    }

    /// Run an in-process sidecar's handler for one event, then transition the
    /// event row to `completed` (or `failed` on throw). Detached from the tick
    /// so a slow handler doesn't stall the queue — the tick's job is to
    /// dispatch, not to wait.
    ///
    /// If the handler is missing (sidecar was unregistered between enqueue and
    /// tick, e.g. tier flipped mid-flight), the event is left `assigned`.
    /// A subsequent tick with the handler re-registered will pick it up; if
    /// none ever comes, `HealthMonitor.reclaimStrandedEvents` won't touch it
    /// (assigned-with-no-busy-worker is exactly the shape it ignores) so we
    /// don't churn — the row just sits until a manual clean-up or the next
    /// deploy. Acceptable for a helper path.
    private func dispatchInProcess(event evt: PendingWorkerEvent) async {
        guard let name = SidecarInProcessKey.name(fromSessionKey: evt.assignedTo) else {
            logger.warning("EventPusher: malformed inproc sessionKey \(evt.assignedTo) on event \(evt.id)")
            return
        }
        guard let handler = SidecarInProcessRegistry.shared.handler(forName: name) else {
            // Sidecar was unregistered between enqueue and delivery. Leave
            // assigned; the next tick with a re-registered handler will pick
            // it up. Take it out of `knownWorkerEventIds` so we retry.
            knownWorkerEventIds.remove(evt.id)
            return
        }

        let payload = SidecarEventPayload(
            eventId: evt.id, type: evt.type, payloadJSON: evt.payload
        )
        let dbPool = self.dbPool
        let logger = self.logger

        Task.detached { [dbPool, logger] in
            let now = nowMs()
            do {
                try await handler(payload)
                do {
                    try await dbPool.write { db in
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET status = 'completed', completedAt = ?,
                                result = 'in-process handler returned'
                            WHERE id = ? AND status = 'assigned'
                        """, arguments: [now, evt.id])
                    }
                } catch {
                    logger.warning("EventPusher: failed to mark in-process event \(evt.id) completed: \(error)")
                }
            } catch {
                logger.warning("EventPusher: in-process handler for '\(name)' threw on event \(evt.id): \(error)")
                do {
                    try await dbPool.write { db in
                        try db.execute(sql: """
                            UPDATE workerEvents
                            SET status = 'failed', completedAt = ?,
                                result = ?
                            WHERE id = ? AND status = 'assigned'
                        """, arguments: [now, "in-process handler threw: \(error.localizedDescription)", evt.id])
                    }
                } catch {
                    logger.warning("EventPusher: failed to mark in-process event \(evt.id) failed: \(error)")
                }
            }
        }
    }

    /// Per-event-type inline reminder that ships with the SSE content.
    /// Overrides any cached rules the worker's --resume context may carry.
    /// Only emitted for event types that changed semantics recently; return
    /// nil for types whose contract is stable.
    private func inlineHandlingReminder(
        for eventType: String, eventId: String, payloadJSON: String
    ) -> String? {
        switch eventType {
        case "sonar_dm":
            let messageId: String = {
                guard let data = payloadJSON.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let dict = obj as? [String: Any],
                      let mid = dict["message_id"] as? String else { return "<see payload.message_id>" }
                return mid
            }()
            // Low-key parenthesized hint — the concrete ids for this event
            // alongside a pointer to the recipient's own SONAR_DM handling
            // section. Deliberately NOT phrased as an override / authoritative
            // rule / "MANDATORY step" contract: that phrasing reads exactly
            // like a prompt injection attempt to any properly-trained model
            // and got flagged as such during the 2026-07-15 fleet-behavior
            // investigation. A soft reference lets --resumed workers with
            // stale cached rules still notice the current shape without
            // triggering injection heuristics.
            //
            // The ids matter: dm_ack and dm_reply use message_id to route the
            // response through the message chain back to the specific sender
            // session that originated this DM. Wrong id → response lands on a
            // random worker on the peer instead of the waiting sender.
            return """
                (This DM's identifiers, to route the response back to the sender's session:
                   message_id: \(messageId)
                   event_id:   \(eventId)
                 Handle per the SONAR_DM section of your instructions — use dm_reply (not sonar_send / dm_send) so the message chain routes back to the originating session; sonar_send would open a fresh thread that gets dispatched to a random worker.)
                """
        default:
            return nil
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
