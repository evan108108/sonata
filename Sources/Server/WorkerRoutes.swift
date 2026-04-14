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

struct WorkerHeartbeatRequest: Decodable { let workerId: String }

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

/// Sweep workers whose lastHeartbeat is older than 60s ago, set them offline.
private func sweepStaleWorkers(in db: Database) throws {
    let cutoff = nowMs() - 60_000
    try db.execute(
        sql: """
        UPDATE workers SET status = 'offline'
        WHERE lastHeartbeat < ? AND status != 'offline'
        """,
        arguments: [cutoff]
    )
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
                    sql: "UPDATE workers SET lastHeartbeat = ? WHERE workerId = ?",
                    arguments: [now, body.workerId]
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

    // GET /api/worker/list — list all workers
    api.get("/list") { _, _ -> Response in
        do {
            let rows = try await dbPool.read { db in
                try WorkerRow.fetchAll(db, sql: "SELECT * FROM workers ORDER BY lastHeartbeat DESC")
            }
            return jsonResponse(rows.map(workerToResponse))
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
                // Find highest priority pending event
                guard let row = try WorkerEventRow.fetchOne(db,
                    sql: "SELECT * FROM workerEvents WHERE status = 'pending' ORDER BY priority DESC, createdAt ASC LIMIT 1"
                ) else {
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
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/worker/events/fail?eventId= — set failed
    events.post("/fail") { request, _ -> Response in
        guard let eventId = request.uri.queryParameters["eventId"].map(String.init), !eventId.isEmpty else {
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
                    sql: "UPDATE workerEvents SET status = 'failed', completedAt = ? WHERE id = ?",
                    arguments: [now, eventId]
                )

                if let workerId = row?.assignedTo {
                    try db.execute(
                        sql: "UPDATE workers SET status = 'idle', currentEventId = NULL WHERE workerId = ?",
                        arguments: [workerId]
                    )
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
