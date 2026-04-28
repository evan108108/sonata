import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/worker routes.
// Handler logic is duplicated from WorkerRoutes.swift.

// MARK: - Response shapes specific to actions

private struct WorkerListItem: Encodable {
    let _id: String
    let workerId: String
    let sessionLabel: String
    let status: String
    let capabilities: String  // raw JSON string, matching existing route behaviour
    let lastHeartbeat: Int64
    let currentEventId: String
    let registeredAt: Int64
    let currentTask: String?
    let assignedAt: Int64?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(workerId, forKey: .workerId)
        try c.encode(sessionLabel, forKey: .sessionLabel)
        try c.encode(status, forKey: .status)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(lastHeartbeat, forKey: .lastHeartbeat)
        try c.encode(currentEventId, forKey: .currentEventId)
        try c.encode(registeredAt, forKey: .registeredAt)
        try c.encodeIfPresent(currentTask, forKey: .currentTask)
        try c.encodeIfPresent(assignedAt, forKey: .assignedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, workerId, sessionLabel, status, capabilities
        case lastHeartbeat, currentEventId, registeredAt, currentTask, assignedAt
    }
}

// MARK: - Helpers

/// Sweep workers whose lastHeartbeat is older than 60s ago, set them offline,
/// fail their active events and associated tasks. Mirrors sweepStaleWorkers in WorkerRoutes.swift.
private func sweepStaleWorkersForActions(in db: Database) throws {
    let cutoff = nowMs() - 60_000

    let staleWorkers = try Row.fetchAll(db, sql: """
        SELECT workerId, currentEventId FROM workers
        WHERE lastHeartbeat < ? AND status != 'offline'
    """, arguments: [cutoff])

    try db.execute(sql: """
        UPDATE workers SET status = 'offline'
        WHERE lastHeartbeat < ? AND status != 'offline'
    """, arguments: [cutoff])

    let now = nowMs()
    for row in staleWorkers {
        do {
            guard let workerId = row["workerId"] as? String,
                  let eventId = row["currentEventId"] as? String, !eventId.isEmpty else { continue }

            try db.execute(sql: """
                UPDATE workerEvents SET status = 'failed', result = 'Worker lost heartbeat', completedAt = ?
                WHERE id = ? AND status = 'assigned'
            """, arguments: [now, eventId])

            if let event = try Row.fetchOne(db, sql: "SELECT payload FROM workerEvents WHERE id = ?", arguments: [eventId]),
               let payload = event["payload"] as? String,
               let payloadData = payload.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
               let taskId = json["task_id"] as? String {
                try db.execute(sql: """
                    UPDATE tasks SET status = 'failed', lastError = 'Worker lost heartbeat', updatedAt = ?
                    WHERE id = ? AND status = 'active'
                """, arguments: [now, taskId])

                let dependents = try Row.fetchAll(db, sql: """
                    SELECT id, blockedBy FROM tasks WHERE status = 'pending' AND blockedBy LIKE ?
                """, arguments: ["%\(taskId)%"])
                for dep in dependents {
                    guard let depId = dep["id"] as? String else { continue }
                    let blockedByJSON = dep["blockedBy"] as? String ?? "[]"
                    if let data = blockedByJSON.data(using: .utf8),
                       var arr = try? JSONDecoder().decode([String].self, from: data) {
                        arr = arr.flatMap { s -> [String] in
                            let t = s.trimmingCharacters(in: .whitespaces)
                            if t.hasPrefix("["),
                               let d = t.data(using: .utf8),
                               let inner = try? JSONDecoder().decode([String].self, from: d) {
                                return inner
                            }
                            return [s]
                        }
                        arr.removeAll { $0 == taskId }
                        if let newJSON = try? JSONEncoder().encode(arr),
                           let newStr = String(data: newJSON, encoding: .utf8) {
                            try db.execute(sql: "UPDATE tasks SET blockedBy = ?, updatedAt = ? WHERE id = ?",
                                           arguments: [newStr, now, depId])
                        }
                    }
                }
            }

            try db.execute(sql: "UPDATE workers SET currentEventId = NULL WHERE workerId = ?",
                           arguments: [workerId])
        } catch {
            continue
        }
    }
}

let workerActions: [SonataAction] = [

    // POST /api/worker/register — upsert worker by workerId, sweep stale
    SonataAction(
        name: "worker_register",
        description: "Register a worker (upsert by workerId) and sweep stale workers.",
        group: "/api/worker",
        path: "/register",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier"),
            ActionParam("sessionLabel", .string, required: true, description: "Human-readable session label"),
            ActionParam("capabilities", .stringArray, description: "Capabilities (comma-separated or array)"),
            ActionParam("sessionId", .string, description: "Claude session UUID for cycling/resume"),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            let sessionLabel = ctx.params.string("sessionLabel") ?? ""
            let sessionId = ctx.params.string("sessionId")

            let now = nowMs()
            let capsJSON = encodeTags(ctx.params.stringArray("capabilities") ?? [])

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO workers (id, workerId, sessionLabel, status, capabilities, lastHeartbeat, registeredAt, sessionId)
                        VALUES (?, ?, ?, 'idle', ?, ?, ?, ?)
                        ON CONFLICT(workerId) DO UPDATE SET
                            sessionLabel = excluded.sessionLabel,
                            capabilities = excluded.capabilities,
                            lastHeartbeat = excluded.lastHeartbeat,
                            sessionId = excluded.sessionId,
                            status = 'idle'
                        """,
                        arguments: [newUUID(), workerId, sessionLabel, capsJSON, now, now, sessionId]
                    )
                    try sweepStaleWorkersForActions(in: db)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/worker/heartbeat — update lastHeartbeat, sweep stale
    SonataAction(
        name: "worker_heartbeat",
        description: "Heartbeat a worker; update lastHeartbeat and sweep stale workers.",
        group: "/api/worker",
        path: "/heartbeat",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier"),
            ActionParam("lastProgressAt", .integer, description: "Last progress timestamp (epoch ms)"),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            let lastProgressAt = ctx.params.int("lastProgressAt").map { Int64($0) }

            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE workers SET lastHeartbeat = ?, lastProgressAt = COALESCE(?, lastProgressAt) WHERE workerId = ?",
                        arguments: [now, lastProgressAt, workerId]
                    )
                    try sweepStaleWorkersForActions(in: db)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/worker/unregister?workerId= — delete worker
    SonataAction(
        name: "worker_unregister",
        description: "Unregister a worker by workerId.",
        group: "/api/worker",
        path: "/unregister",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier", source: .query),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM workers WHERE workerId = ?", arguments: [workerId])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/worker/purge — delete stale workers, unassign their events
    SonataAction(
        name: "worker_purge",
        description: "Purge workers whose lastHeartbeat is older than 60s; unassign their events.",
        group: "/api/worker",
        path: "/purge",
        method: .post,
        params: [],
        handler: { ctx in
            let cutoff = nowMs() - 60_000
            do {
                let purged = try await ctx.dbPool.write { db -> Int in
                    let staleRows = try Row.fetchAll(db,
                        sql: "SELECT workerId FROM workers WHERE lastHeartbeat < ?",
                        arguments: [cutoff]
                    )
                    let staleIds = staleRows.map { $0["workerId"] as String }

                    for wid in staleIds {
                        try db.execute(
                            sql: """
                            UPDATE workerEvents SET assignedTo = NULL, status = 'pending'
                            WHERE assignedTo = ? AND status = 'assigned'
                            """,
                            arguments: [wid]
                        )
                    }

                    try db.execute(
                        sql: "DELETE FROM workers WHERE lastHeartbeat < ?",
                        arguments: [cutoff]
                    )
                    return staleIds.count
                }
                return PurgeResponse(purged: purged)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/worker/list — all workers with current task info
    SonataAction(
        name: "worker_list",
        description: "List all workers with their current task, heartbeat, and status.",
        group: "/api/worker",
        path: "/list",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows: [Row] = try await ctx.dbPool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT w.*,
                            COALESCE(
                                json_extract(e.payload, '$.title'),
                                t.title
                            ) as currentTask,
                            e.assignedAt as eventAssignedAt
                        FROM workers w
                        LEFT JOIN workerEvents e ON w.currentEventId = e.id
                        LEFT JOIN tasks t ON json_extract(e.payload, '$.task_id') = t.id
                        ORDER BY w.lastHeartbeat DESC
                    """)
                }
                return rows.map { row -> WorkerListItem in
                    WorkerListItem(
                        _id: row["id"] as? String ?? "",
                        workerId: row["workerId"] as? String ?? "",
                        sessionLabel: row["sessionLabel"] as? String ?? "",
                        status: row["status"] as? String ?? "offline",
                        capabilities: row["capabilities"] as? String ?? "[]",
                        lastHeartbeat: row["lastHeartbeat"] as? Int64 ?? 0,
                        currentEventId: row["currentEventId"] as? String ?? "",
                        registeredAt: row["registeredAt"] as? Int64 ?? 0,
                        currentTask: row["currentTask"] as? String,
                        assignedAt: row["eventAssignedAt"] as? Int64
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/worker/drain — mark worker as draining (cycling)
    SonataAction(
        name: "worker_drain",
        description: "Mark a worker as draining so it won't receive new events.",
        group: "/api/worker",
        path: "/drain",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier", source: .query),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "UPDATE workers SET status = 'draining' WHERE workerId = ?",
                                   arguments: [workerId])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/worker/undrain — un-drain a worker (cycle abort)
    SonataAction(
        name: "worker_undrain",
        description: "Un-drain a worker, setting it back to idle.",
        group: "/api/worker",
        path: "/undrain",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier", source: .query),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "UPDATE workers SET status = 'idle' WHERE workerId = ?",
                                   arguments: [workerId])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/worker/status — summary
    SonataAction(
        name: "worker_status",
        description: "Summary worker status: online, busy, pending event counts.",
        group: "/api/worker",
        path: "/status",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let cutoff = nowMs() - 60_000
                return try await ctx.dbPool.read { db -> WorkerStatusResponse in
                    let online = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM workers WHERE lastHeartbeat >= ?",
                        arguments: [cutoff]
                    ) ?? 0
                    let busy = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM workers WHERE status = 'busy' AND lastHeartbeat >= ?",
                        arguments: [cutoff]
                    ) ?? 0
                    let pending = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM workerEvents WHERE status = 'pending'"
                    ) ?? 0
                    return WorkerStatusResponse(online: online, busy: busy, pendingEvents: pending)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]

// MARK: - Inspector Action

let inspectorAction: [SonataAction] = [
    SonataAction(
        name: "worker_inspect",
        description: "Open an inspector window to resume a past worker session.",
        group: "/api/worker",
        path: "/inspect",
        method: .post,
        params: [
            ActionParam("sessionId", .string, required: true, description: "Claude session UUID to resume"),
            ActionParam("title", .string, description: "Task title for window label"),
        ],
        handler: { ctx in
            let sessionId = try ctx.params.require("sessionId")
            let title = ctx.params.string("title") ?? "Inspector"
            DispatchQueue.main.async {
                let controller = InspectorWindowController(sessionId: sessionId, taskTitle: title)
                controller.open()
                InspectorWindowStore.shared.add(controller)
            }
            return SuccessResponse()
        }
    ),
]

// MARK: - Worker Event Actions (claim, complete, fail, recent, enqueue)

private func eventToResponse(_ row: WorkerEventRow) -> WorkerEventResponse {
    WorkerEventResponse(
        _id: row.id,
        type: row.type,
        payload: row.payload,
        priority: row.priority,
        assignedTo: row.assignedTo,
        status: row.status,
        result: row.result,
        createdAt: row.createdAt,
        assignedAt: row.assignedAt,
        completedAt: row.completedAt,
        sessionId: row.sessionId
    )
}

private struct ClaimedFalseResponse: Encodable {
    let claimed = false
}

let workerEventActions: [SonataAction] = [

    // POST /api/worker/events/enqueue — create a worker event
    SonataAction(
        name: "worker_event_enqueue",
        description: "Create a pending worker event.",
        group: "/api/worker/events",
        path: "/enqueue",
        method: .post,
        params: [
            ActionParam("type", .string, required: true, description: "Event type (email, task, alert)"),
            ActionParam("payload", .string, required: true, description: "JSON payload"),
            ActionParam("priority", .integer, description: "Priority 1-10 (default 5)"),
        ],
        handler: { ctx in
            let type = try ctx.params.require("type")
            let payload = try ctx.params.require("payload")
            let priority = ctx.params.int("priority") ?? 5
            let now = nowMs()
            let id = newUUID()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: """
                        INSERT INTO workerEvents (id, type, payload, priority, status, createdAt)
                        VALUES (?, ?, ?, ?, 'pending', ?)
                    """, arguments: [id, type, payload, priority, now])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // POST /api/worker/events/claim — claim next pending event for a worker
    SonataAction(
        name: "worker_event_claim",
        description: "Claim the next pending worker event. Returns the event or {claimed:false}.",
        group: "/api/worker/events",
        path: "/claim",
        method: .post,
        params: [
            ActionParam("workerId", .string, required: true, description: "Worker identifier"),
        ],
        handler: { ctx in
            let workerId = try ctx.params.require("workerId")
            let now = nowMs()
            do {
                let event = try await ctx.dbPool.write { db -> WorkerEventRow? in
                    // Don't let a busy or draining worker claim events
                    let workerRow = try Row.fetchOne(db, sql: """
                        SELECT currentEventId, status FROM workers WHERE workerId = ?
                    """, arguments: [workerId])
                    if let workerRow {
                        let status = workerRow["status"] as? String ?? ""
                        let currentEvent = workerRow["currentEventId"] as? String
                        if currentEvent != nil || status == "draining" { return nil }
                    }

                    // Find event: pre-assigned to this worker first, then any pending
                    guard let row = try WorkerEventRow.fetchOne(db, sql: """
                        SELECT * FROM workerEvents
                        WHERE (status = 'assigned' AND assignedTo = ?) OR status = 'pending'
                        ORDER BY
                            CASE WHEN status = 'assigned' AND assignedTo = ? THEN 0 ELSE 1 END,
                            priority DESC, createdAt ASC
                        LIMIT 1
                    """, arguments: [workerId, workerId]) else {
                        return nil
                    }

                    // Look up worker's sessionId for cycling/resume
                    let workerSessionId = try String.fetchOne(db, sql: """
                        SELECT sessionId FROM workers WHERE workerId = ?
                    """, arguments: [workerId])

                    // Assign it (copy sessionId from worker to event)
                    try db.execute(sql: """
                        UPDATE workerEvents SET assignedTo = ?, status = 'assigned', assignedAt = ?, sessionId = ?
                        WHERE id = ?
                    """, arguments: [workerId, now, workerSessionId, row.id])

                    // Mark worker busy
                    try db.execute(sql: """
                        UPDATE workers SET status = 'busy', currentEventId = ? WHERE workerId = ?
                    """, arguments: [row.id, workerId])

                    return try WorkerEventRow.fetchOne(db,
                        sql: "SELECT * FROM workerEvents WHERE id = ?",
                        arguments: [row.id])
                }
                if let event {
                    return eventToResponse(event)
                } else {
                    return ClaimedFalseResponse()
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/worker/events/complete — mark event completed, free worker
    SonataAction(
        name: "worker_event_complete",
        description: "Mark a worker event as completed and set worker back to idle.",
        group: "/api/worker/events",
        path: "/complete",
        method: .post,
        params: [
            ActionParam("eventId", .string, required: true, description: "Event ID"),
            ActionParam("workerId", .string, description: "Worker ID (optional)"),
            ActionParam("result", .string, description: "Result summary"),
        ],
        handler: { ctx in
            let eventId = try ctx.params.require("eventId")
            let resultText = ctx.params.string("result")
            let now = nowMs()
            var completedWorkerId: String?
            do {
                try await ctx.dbPool.write { db in
                    let row = try WorkerEventRow.fetchOne(db,
                        sql: "SELECT * FROM workerEvents WHERE id = ?",
                        arguments: [eventId])

                    try db.execute(sql: """
                        UPDATE workerEvents SET status = 'completed', result = ?, completedAt = ? WHERE id = ?
                    """, arguments: [resultText, now, eventId])

                    // Set worker back to idle (unless draining — keep draining status)
                    if let workerId = row?.assignedTo {
                        completedWorkerId = workerId
                        let workerStatus = try String.fetchOne(db, sql: """
                            SELECT status FROM workers WHERE workerId = ?
                        """, arguments: [workerId])
                        let newStatus = workerStatus == "draining" ? "draining" : "idle"
                        try db.execute(sql: """
                            UPDATE workers SET status = ?, currentEventId = NULL WHERE workerId = ?
                        """, arguments: [newStatus, workerId])
                    }

                    // Complete associated task + unblock dependents + parent rollup
                    if let payload = row?.payload,
                       let payloadData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                       let taskId = json["task_id"] as? String {
                        try db.execute(sql: """
                            UPDATE tasks SET status = 'completed', result = ?, completedAt = ?, updatedAt = ?
                            WHERE id = ? AND status = 'active'
                        """, arguments: [resultText ?? "Completed via channel", now, now, taskId])
                        try unblockDependents(taskId: taskId, in: db, now: now)
                        try rollUpParentStatus(childTaskId: taskId, in: db, now: now)
                    }
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            // Notify WorkerManager for cycling evaluation
            if let wid = completedWorkerId {
                DispatchQueue.main.async {
                    WorkerManager.shared.onEventCompleted(workerId: wid)
                }
            }

            return SuccessResponse()
        }
    ),

    // POST /api/worker/events/fail — mark event failed, free worker
    SonataAction(
        name: "worker_event_fail",
        description: "Mark a worker event as failed and set worker back to idle.",
        group: "/api/worker/events",
        path: "/fail",
        method: .post,
        params: [
            ActionParam("eventId", .string, required: true, description: "Event ID"),
            ActionParam("workerId", .string, description: "Worker ID (optional)"),
            ActionParam("error", .string, description: "Error description"),
        ],
        handler: { ctx in
            let eventId = try ctx.params.require("eventId")
            let errorText = ctx.params.string("error")
            let now = nowMs()
            var completedWorkerId: String?
            do {
                try await ctx.dbPool.write { db in
                    let row = try WorkerEventRow.fetchOne(db,
                        sql: "SELECT * FROM workerEvents WHERE id = ?",
                        arguments: [eventId])

                    try db.execute(sql: """
                        UPDATE workerEvents SET status = 'failed', result = ?, completedAt = ? WHERE id = ?
                    """, arguments: [errorText, now, eventId])

                    if let workerId = row?.assignedTo {
                        completedWorkerId = workerId
                        let workerStatus = try String.fetchOne(db, sql: """
                            SELECT status FROM workers WHERE workerId = ?
                        """, arguments: [workerId])
                        let newStatus = workerStatus == "draining" ? "draining" : "idle"
                        try db.execute(sql: """
                            UPDATE workers SET status = ?, currentEventId = NULL WHERE workerId = ?
                        """, arguments: [newStatus, workerId])
                    }

                    // Fail associated task + unblock dependents + parent rollup
                    if let payload = row?.payload,
                       let payloadData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                       let taskId = json["task_id"] as? String {
                        try db.execute(sql: """
                            UPDATE tasks SET status = 'failed', lastError = ?, updatedAt = ?
                            WHERE id = ? AND status = 'active'
                        """, arguments: [errorText ?? "Failed via channel", now, taskId])
                        try unblockDependents(taskId: taskId, in: db, now: now)
                        try rollUpParentStatus(childTaskId: taskId, in: db, now: now)
                    }
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            // Notify WorkerManager for cycling evaluation
            if let wid = completedWorkerId {
                DispatchQueue.main.async {
                    WorkerManager.shared.onEventCompleted(workerId: wid)
                }
            }

            return SuccessResponse()
        }
    ),

    // GET /api/worker/events/recent — list recent worker events
    SonataAction(
        name: "worker_event_recent",
        description: "List recent worker events ordered by createdAt DESC.",
        group: "/api/worker/events",
        path: "/recent",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 20)"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 20
            do {
                let rows = try await ctx.dbPool.read { db in
                    try WorkerEventRow.fetchAll(db,
                        sql: "SELECT * FROM workerEvents ORDER BY createdAt DESC LIMIT ?",
                        arguments: [limit])
                }
                return rows.map { eventToResponse($0) }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
