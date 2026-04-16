import Foundation
import Hummingbird
import GRDB

// MARK: - Database Rows

struct WorkerRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "workers"

    var id: String
    var workerId: String
    var sessionLabel: String
    var status: String
    var capabilities: String
    var lastHeartbeat: Int64
    var currentEventId: String?
    var registeredAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, workerId, sessionLabel, status, capabilities
        case lastHeartbeat, currentEventId, registeredAt
    }
}

struct WorkerEventRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "workerEvents"

    var id: String
    var type: String
    var payload: String
    var priority: Int
    var assignedTo: String?
    var status: String
    var result: String?
    var createdAt: Int64
    var assignedAt: Int64?
    var completedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, type, payload, priority, assignedTo, status
        case result, createdAt, assignedAt, completedAt
    }
}

// MARK: - Request Bodies

struct WorkerHeartbeatRequest: Decodable {
    let workerId: String
    let lastProgressAt: Int64?
}

struct RegisterWorkerRequest: Decodable {
    let workerId: String
    let sessionLabel: String
    let capabilities: [String]?
}

struct CompleteEventBody: Decodable {
    let eventId: String
    let workerId: String?
    let result: String?
}

struct FailEventBody: Decodable {
    let eventId: String
    let workerId: String?
    let error: String?
}

struct EnqueueEventRequest: Decodable {
    let type: String
    let payload: String
    let priority: Int?
}

// MARK: - Response Types

struct WorkerResponse: Encodable {
    let _id: String
    let workerId: String
    let sessionLabel: String
    let status: String
    let capabilities: [String]
    let lastHeartbeat: Int64
    let currentEventId: String?
    let registeredAt: Int64
}

struct WorkerEventResponse: Encodable {
    let _id: String
    let type: String
    let payload: String
    let priority: Int
    let assignedTo: String?
    let status: String
    let result: String?
    let createdAt: Int64
    let assignedAt: Int64?
    let completedAt: Int64?
}

struct WorkerStatusResponse: Encodable {
    let online: Int
    let busy: Int
    let pendingEvents: Int
}

struct PurgeResponse: Encodable {
    let purged: Int
    let success = true
}

// MARK: - Helpers

private func workerToResponse(_ row: WorkerRow) -> WorkerResponse {
    WorkerResponse(
        _id: row.id,
        workerId: row.workerId,
        sessionLabel: row.sessionLabel,
        status: row.status,
        capabilities: parseTags(row.capabilities),
        lastHeartbeat: row.lastHeartbeat,
        currentEventId: row.currentEventId,
        registeredAt: row.registeredAt
    )
}

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
        completedAt: row.completedAt
    )
}

/// Sweep workers whose lastHeartbeat is older than 60s ago, set them offline,
/// fail their active events and associated tasks.
private func sweepStaleWorkers(in db: Database) throws {
    let cutoff = nowMs() - 60_000

    // Find workers going offline
    let staleWorkers = try Row.fetchAll(db, sql: """
        SELECT workerId, currentEventId FROM workers
        WHERE lastHeartbeat < ? AND status != 'offline'
    """, arguments: [cutoff])

    // Mark them offline
    try db.execute(sql: """
        UPDATE workers SET status = 'offline'
        WHERE lastHeartbeat < ? AND status != 'offline'
    """, arguments: [cutoff])

    // Fail their active events and tasks
    let now = nowMs()
    for row in staleWorkers {
        do {
            guard let workerId = row["workerId"] as? String,
                  let eventId = row["currentEventId"] as? String, !eventId.isEmpty else { continue }

            // Fail the event
            try db.execute(sql: """
                UPDATE workerEvents SET status = 'failed', result = 'Worker lost heartbeat', completedAt = ?
                WHERE id = ? AND status = 'assigned'
            """, arguments: [now, eventId])

            // Find and fail the associated task
            if let event = try Row.fetchOne(db, sql: "SELECT payload FROM workerEvents WHERE id = ?", arguments: [eventId]),
               let payload = event["payload"] as? String,
               let payloadData = payload.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
               let taskId = json["task_id"] as? String {
                try db.execute(sql: """
                    UPDATE tasks SET status = 'failed', lastError = 'Worker lost heartbeat', updatedAt = ?
                    WHERE id = ? AND status = 'active'
                """, arguments: [now, taskId])

                // Unblock dependents of the failed task
                let dependents = try Row.fetchAll(db, sql: """
                    SELECT id, blockedBy FROM tasks WHERE status = 'pending' AND blockedBy LIKE ?
                """, arguments: ["%\(taskId)%"])
                for dep in dependents {
                    guard let depId = dep["id"] as? String else { continue }
                    let blockedByJSON = dep["blockedBy"] as? String ?? "[]"
                    if let data = blockedByJSON.data(using: .utf8),
                       var arr = try? JSONDecoder().decode([String].self, from: data) {
                        arr.removeAll { $0 == taskId }
                        if let newJSON = try? JSONEncoder().encode(arr),
                           let newStr = String(data: newJSON, encoding: .utf8) {
                            try db.execute(sql: "UPDATE tasks SET blockedBy = ?, updatedAt = ? WHERE id = ?",
                                           arguments: [newStr, now, depId])
                        }
                    }
                }
            }

            // Clear the worker's event assignment
            try db.execute(sql: "UPDATE workers SET currentEventId = NULL WHERE workerId = ?",
                           arguments: [workerId])
        } catch {
            // One bad worker shouldn't block the entire sweep
            continue
        }
    }
}

// MARK: - Route Registration

public func registerWorkerRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/worker")

    // POST /api/worker/register — upsert worker by workerId, sweep stale
    api.post("/register") { request, context -> Response in
        guard let body = try? await request.decode(as: RegisterWorkerRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.workerId.isEmpty else {
            return errorResponse("workerId is required")
        }

        let now = nowMs()
        let capsJSON = encodeTags(body.capabilities ?? [])

        do {
            try await dbPool.write { db in
                // Upsert by workerId
                try db.execute(
                    sql: """
                    INSERT INTO workers (id, workerId, sessionLabel, status, capabilities, lastHeartbeat, registeredAt)
                    VALUES (?, ?, ?, 'idle', ?, ?, ?)
                    ON CONFLICT(workerId) DO UPDATE SET
                        sessionLabel = excluded.sessionLabel,
                        capabilities = excluded.capabilities,
                        lastHeartbeat = excluded.lastHeartbeat,
                        status = 'idle'
                    """,
                    arguments: [newUUID(), body.workerId, body.sessionLabel, capsJSON, now, now]
                )
                try sweepStaleWorkers(in: db)
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse(), status: .created)
    }

    // POST /api/worker/heartbeat — update lastHeartbeat, sweep stale
    api.post("/heartbeat") { request, context -> Response in
        guard let body = try? await request.decode(as: WorkerHeartbeatRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE workers SET lastHeartbeat = ?, lastProgressAt = COALESCE(?, lastProgressAt) WHERE workerId = ?",
                    arguments: [now, body.lastProgressAt, body.workerId]
                )
                try sweepStaleWorkers(in: db)
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/worker/unregister?workerId= — delete worker
    api.post("/unregister") { request, _ -> Response in
        guard let workerId = request.uri.queryParameters["workerId"].map(String.init), !workerId.isEmpty else {
            return errorResponse("workerId parameter is required")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM workers WHERE workerId = ?", arguments: [workerId])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/worker/purge — delete stale workers, unassign their events
    api.post("/purge") { request, _ -> Response in
        let cutoff = nowMs() - 60_000

        do {
            let purged = try await dbPool.write { db -> Int in
                // Get stale worker IDs
                let staleRows = try Row.fetchAll(db,
                    sql: "SELECT workerId FROM workers WHERE lastHeartbeat < ?",
                    arguments: [cutoff]
                )
                let staleIds = staleRows.map { $0["workerId"] as String }

                // Unassign events from stale workers
                for wid in staleIds {
                    try db.execute(
                        sql: """
                        UPDATE workerEvents SET assignedTo = NULL, status = 'pending'
                        WHERE assignedTo = ? AND status = 'assigned'
                        """,
                        arguments: [wid]
                    )
                }

                // Delete stale workers
                try db.execute(
                    sql: "DELETE FROM workers WHERE lastHeartbeat < ?",
                    arguments: [cutoff]
                )
                return staleIds.count
            }
            return jsonResponse(PurgeResponse(purged: purged))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/worker/list — all workers with current task info
    api.get("/list") { _, _ -> Response in
        do {
            let rows: [Row] = try await dbPool.read { db in
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
            let result = rows.map { row -> [String: Any] in
                var dict: [String: Any] = [
                    "_id": row["id"] as? String ?? "",
                    "workerId": row["workerId"] as? String ?? "",
                    "sessionLabel": row["sessionLabel"] as? String ?? "",
                    "status": row["status"] as? String ?? "offline",
                    "capabilities": row["capabilities"] as? String ?? "[]",
                    "lastHeartbeat": row["lastHeartbeat"] as? Int64 ?? 0,
                    "currentEventId": row["currentEventId"] as? String ?? "",
                    "registeredAt": row["registeredAt"] as? Int64 ?? 0,
                ]
                if let task = row["currentTask"] as? String {
                    dict["currentTask"] = task
                }
                if let assignedAt = row["eventAssignedAt"] as? Int64 {
                    dict["assignedAt"] = assignedAt
                }
                return dict
            }
            let data = try JSONSerialization.data(withJSONObject: result)
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: data)))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/worker/status — summary
    api.get("/status") { _, _ -> Response in
        do {
            let cutoff = nowMs() - 60_000
            let status = try await dbPool.read { db -> WorkerStatusResponse in
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
            return jsonResponse(status)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // MARK: Events

    let events = api.group("/events")

    // POST /api/worker/events/enqueue — create worker event
    events.post("/enqueue") { request, context -> Response in
        guard let body = try? await request.decode(as: EnqueueEventRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.type.isEmpty else {
            return errorResponse("type is required")
        }

        let now = nowMs()
        let id = newUUID()

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO workerEvents (id, type, payload, priority, status, createdAt)
                    VALUES (?, ?, ?, ?, 'pending', ?)
                    """,
                    arguments: [id, body.type, body.payload, body.priority ?? 5, now]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(StoreResponse(id: id), status: .created)
    }

    // POST /api/worker/events/claim — accepts workerId via query param OR JSON body
    events.post("/claim") { request, context -> Response in
        var workerId = request.uri.queryParameters["workerId"].map(String.init) ?? ""
        if workerId.isEmpty {
            if let body = try? await request.decode(as: WorkerHeartbeatRequest.self, context: context) {
                workerId = body.workerId
            }
        }
        guard !workerId.isEmpty else {
            return errorResponse("workerId parameter is required")
        }

        let now = nowMs()

        do {
            let event = try await dbPool.write { db -> WorkerEventRow? in
                // Guard: don't let a busy worker claim a second event
                let currentEvent = try String.fetchOne(db, sql: """
                    SELECT currentEventId FROM workers WHERE workerId = ? AND currentEventId IS NOT NULL
                """, arguments: [workerId])
                if currentEvent != nil {
                    return nil  // Already busy — reject claim
                }

                // Find event: first check for events pre-assigned to this worker, then pending
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

                // Assign it
                try db.execute(
                    sql: """
                    UPDATE workerEvents SET assignedTo = ?, status = 'assigned', assignedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [workerId, now, row.id]
                )

                // Mark worker as busy
                try db.execute(
                    sql: "UPDATE workers SET status = 'busy', currentEventId = ? WHERE workerId = ?",
                    arguments: [row.id, workerId]
                )

                return try WorkerEventRow.fetchOne(db,
                    sql: "SELECT * FROM workerEvents WHERE id = ?",
                    arguments: [row.id]
                )
            }

            if let event {
                return jsonResponse(eventToResponse(event))
            } else {
                return jsonResponse(["claimed": false] as [String: Bool])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/worker/events/complete — accepts eventId via query param OR JSON body
    events.post("/complete") { request, context -> Response in
        // Try query param first, fall back to JSON body
        var eventId = request.uri.queryParameters["eventId"].map(String.init) ?? ""
        var resultText: String? = nil
        if eventId.isEmpty {
            if let body = try? await request.decode(as: CompleteEventBody.self, context: context) {
                eventId = body.eventId
                resultText = body.result
            }
        }
        guard !eventId.isEmpty else {
            return errorResponse("eventId parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                // Get event to find assignedTo
                let row = try WorkerEventRow.fetchOne(db,
                    sql: "SELECT * FROM workerEvents WHERE id = ?",
                    arguments: [eventId]
                )

                try db.execute(
                    sql: "UPDATE workerEvents SET status = 'completed', result = ?, completedAt = ? WHERE id = ?",
                    arguments: [resultText, now, eventId]
                )

                // Set worker back to idle
                if let workerId = row?.assignedTo {
                    try db.execute(
                        sql: "UPDATE workers SET status = 'idle', currentEventId = NULL WHERE workerId = ?",
                        arguments: [workerId]
                    )
                }

                // Also complete the associated task + unblock dependents
                do {
                    if let payload = row?.payload,
                       let payloadData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                       let taskId = json["task_id"] as? String {
                        try db.execute(
                            sql: "UPDATE tasks SET status = 'completed', result = ?, completedAt = ?, updatedAt = ? WHERE id = ? AND status = 'active'",
                            arguments: [resultText ?? "Completed via channel", now, now, taskId]
                        )
                        try unblockDependents(taskId: taskId, in: db, now: now)
                    }
                } catch {
                    // Don't fail the event completion if task update fails
                }
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/worker/events/fail — set failed, accepts eventId via query param OR JSON body
    events.post("/fail") { request, context -> Response in
        var eventId = request.uri.queryParameters["eventId"].map(String.init) ?? ""
        var errorText: String? = nil
        if eventId.isEmpty {
            if let body = try? await request.decode(as: FailEventBody.self, context: context) {
                eventId = body.eventId
                errorText = body.error
            }
        }
        guard !eventId.isEmpty else {
            return errorResponse("eventId parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                let row = try WorkerEventRow.fetchOne(db,
                    sql: "SELECT * FROM workerEvents WHERE id = ?",
                    arguments: [eventId]
                )

                try db.execute(
                    sql: "UPDATE workerEvents SET status = 'failed', result = ?, completedAt = ? WHERE id = ?",
                    arguments: [errorText, now, eventId]
                )

                if let workerId = row?.assignedTo {
                    try db.execute(
                        sql: "UPDATE workers SET status = 'idle', currentEventId = NULL WHERE workerId = ?",
                        arguments: [workerId]
                    )
                }

                // Also fail the associated task + unblock dependents
                do {
                    if let payload = row?.payload,
                       let payloadData = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                       let taskId = json["task_id"] as? String {
                        try db.execute(
                            sql: "UPDATE tasks SET status = 'failed', lastError = ?, updatedAt = ? WHERE id = ? AND status = 'active'",
                            arguments: [errorText ?? "Failed via channel", now, taskId]
                        )
                        try unblockDependents(taskId: taskId, in: db, now: now)
                    }
                } catch {
                    // Don't fail the event failure if task update fails
                }
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // GET /api/worker/events/recent?limit= — recent events
    events.get("/recent") { request, _ -> Response in
        let limit = Int(request.uri.queryParameters["limit"] ?? "") ?? 20

        do {
            let rows = try await dbPool.read { db in
                try WorkerEventRow.fetchAll(db,
                    sql: "SELECT * FROM workerEvents ORDER BY createdAt DESC LIMIT ?",
                    arguments: [limit]
                )
            }
            return jsonResponse(rows.map(eventToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
