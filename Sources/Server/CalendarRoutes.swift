import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct CalendarEventRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "calendarEvents"

    var id: String
    var title: String
    var description: String?
    var prompt: String?
    var scheduledAt: Int64
    var recurrence: String?
    var lastRunAt: Int64?
    var lastRunStatus: String?
    var runCount: Int
    var enabled: Int  // SQLite INTEGER (0/1)
    var project: String?
    var workingDir: String?
    var model: String?
    var maxTurns: Int?
    var taskType: String
    var createdAt: Int64
    var updatedAt: Int64
}

// MARK: - Request Bodies

struct CreateCalendarEventRequest: Decodable {
    let title: String
    let description: String?
    let prompt: String?
    let scheduledAt: Int64
    let recurrence: String?
    let enabled: Bool?
    let project: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let taskType: String
}

struct ExecutedCalendarBody: Decodable {
    let status: String?
}

struct UpdateCalendarEventRequest: Decodable {
    let id: String
    let title: String?
    let description: String?
    let prompt: String?
    let scheduledAt: Int64?
    let recurrence: String?
    let enabled: Bool?
    let project: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let taskType: String?
}

// MARK: - Response Types

struct CalendarEventResponse: Encodable {
    let _id: String
    let title: String
    let description: String?
    let prompt: String?
    let scheduledAt: Int64
    let recurrence: String?
    let lastRunAt: Int64?
    let lastRunStatus: String?
    let runCount: Int
    let enabled: Bool
    let project: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let taskType: String
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encode(scheduledAt, forKey: .scheduledAt)
        try c.encodeIfPresent(recurrence, forKey: .recurrence)
        try c.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try c.encodeIfPresent(lastRunStatus, forKey: .lastRunStatus)
        try c.encode(runCount, forKey: .runCount)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(workingDir, forKey: .workingDir)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(maxTurns, forKey: .maxTurns)
        try c.encode(taskType, forKey: .taskType)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, title, description, prompt
        case scheduledAt, recurrence
        case lastRunAt, lastRunStatus, runCount
        case enabled, project, workingDir, model, maxTurns, taskType
        case createdAt, updatedAt
    }
}

// MARK: - Helpers

private func rowToCalendarResponse(_ row: CalendarEventRow) -> CalendarEventResponse {
    CalendarEventResponse(
        _id: row.id,
        title: row.title,
        description: row.description,
        prompt: row.prompt,
        scheduledAt: row.scheduledAt,
        recurrence: row.recurrence,
        lastRunAt: row.lastRunAt,
        lastRunStatus: row.lastRunStatus,
        runCount: row.runCount,
        enabled: row.enabled != 0,
        project: row.project,
        workingDir: row.workingDir,
        model: row.model,
        maxTurns: row.maxTurns,
        taskType: row.taskType,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

/// Advance a scheduledAt timestamp by a recurrence interval string.
/// Supports: "daily", "weekly", "monthly", "hourly", "NNm" (minutes), "NNh" (hours), "NNd" (days)
private func advanceSchedule(_ scheduledAt: Int64, by recurrence: String) -> Int64 {
    let msPerMinute: Int64 = 60_000
    let msPerHour: Int64 = 3_600_000
    let msPerDay: Int64 = 86_400_000

    switch recurrence.lowercased() {
    case "hourly":
        return scheduledAt + msPerHour
    case "daily":
        return scheduledAt + msPerDay
    case "weekly":
        return scheduledAt + msPerDay * 7
    case "monthly":
        return scheduledAt + msPerDay * 30
    default:
        // Parse "NNm", "NNh", "NNd"
        let trimmed = recurrence.lowercased().trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("m"), let n = Int64(trimmed.dropLast()) {
            return scheduledAt + n * msPerMinute
        }
        if trimmed.hasSuffix("h"), let n = Int64(trimmed.dropLast()) {
            return scheduledAt + n * msPerHour
        }
        if trimmed.hasSuffix("d"), let n = Int64(trimmed.dropLast()) {
            return scheduledAt + n * msPerDay
        }
        // Fallback: treat as daily
        return scheduledAt + msPerDay
    }
}

// MARK: - Route Registration

public func registerCalendarRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool,
    scheduler: SchedulerActor? = nil
) {
    let api = router.group("/api/calendar")

    // GET /api/calendar/upcoming — enabled events with scheduledAt > now
    api.get("/upcoming") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let limit = Int(queryParams["limit"] ?? "") ?? 50
        let now = nowMs()

        do {
            let rows = try await dbPool.read { db in
                try CalendarEventRow.fetchAll(db, sql: """
                    SELECT * FROM calendarEvents
                    WHERE enabled = 1 AND scheduledAt > ?
                    ORDER BY scheduledAt ASC LIMIT ?
                """, arguments: [now, limit])
            }
            return jsonResponse(rows.map(rowToCalendarResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/calendar/all — all events
    api.get("/all") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let limit = Int(queryParams["limit"] ?? "") ?? 100

        do {
            let rows = try await dbPool.read { db in
                try CalendarEventRow.fetchAll(db, sql: """
                    SELECT * FROM calendarEvents
                    ORDER BY scheduledAt DESC LIMIT ?
                """, arguments: [limit])
            }
            return jsonResponse(rows.map(rowToCalendarResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/calendar/due — enabled events where scheduledAt <= now
    api.get("/due") { _, _ -> Response in
        let now = nowMs()

        do {
            let rows = try await dbPool.read { db in
                try CalendarEventRow.fetchAll(db, sql: """
                    SELECT * FROM calendarEvents
                    WHERE enabled = 1 AND scheduledAt <= ?
                    ORDER BY scheduledAt ASC
                """, arguments: [now])
            }
            return jsonResponse(rows.map(rowToCalendarResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/calendar — create event
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: CreateCalendarEventRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }

        let id = newUUID()
        let now = nowMs()
        let enabled = (body.enabled ?? true) ? 1 : 0

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO calendarEvents
                        (id, title, description, prompt, scheduledAt, recurrence,
                         runCount, enabled, project, workingDir, model, maxTurns,
                         taskType, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id, body.title, body.description, body.prompt,
                        body.scheduledAt, body.recurrence,
                        enabled, body.project, body.workingDir,
                        body.model, body.maxTurns, body.taskType,
                        now, now
                    ]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        // Notify scheduler about the new event
        if let scheduler {
            Task { await scheduler.reload() }
        }

        return jsonResponse(StoreResponse(id: id), status: .created)
    }

    // PATCH /api/calendar — update event
    api.patch("/") { request, context -> Response in
        guard let body = try? await request.decode(as: UpdateCalendarEventRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.id.isEmpty else {
            return errorResponse("Missing id field")
        }

        let now = nowMs()
        var setClauses: [String] = ["updatedAt = ?"]
        var args: [any DatabaseValueConvertible] = [now]

        if let v = body.title       { setClauses.append("title = ?");       args.append(v) }
        if let v = body.description { setClauses.append("description = ?"); args.append(v) }
        if let v = body.prompt      { setClauses.append("prompt = ?");      args.append(v) }
        if let v = body.scheduledAt { setClauses.append("scheduledAt = ?"); args.append(v as Int64) }
        if let v = body.recurrence  { setClauses.append("recurrence = ?");  args.append(v) }
        if let v = body.enabled     { setClauses.append("enabled = ?");     args.append(v ? 1 : 0) }
        if let v = body.project     { setClauses.append("project = ?");     args.append(v) }
        if let v = body.workingDir  { setClauses.append("workingDir = ?");  args.append(v) }
        if let v = body.model       { setClauses.append("model = ?");       args.append(v) }
        if let v = body.maxTurns    { setClauses.append("maxTurns = ?");    args.append(v) }
        if let v = body.taskType    { setClauses.append("taskType = ?");    args.append(v) }

        args.append(body.id)

        let sql = "UPDATE calendarEvents SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

        do {
            try await dbPool.write { db in
                try db.execute(sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        // Notify scheduler about the update
        if let scheduler {
            Task { await scheduler.reload() }
        }

        return jsonResponse(PatchResponse(id: body.id))
    }

    // DELETE /api/calendar?id= — delete event
    api.delete("/") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM calendarEvents WHERE id = ?", arguments: [id])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        // Notify scheduler about the deletion
        if let scheduler {
            Task { await scheduler.reload() }
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/calendar/enable?id= — set enabled=true
    api.post("/enable") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE calendarEvents SET enabled = 1, updatedAt = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/calendar/disable?id= — set enabled=false
    api.post("/disable") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE calendarEvents SET enabled = 0, updatedAt = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/calendar/executed?id= — update lastRunAt, lastRunStatus, increment runCount, advance scheduledAt
    api.post("/executed") { request, context -> Response in
        let queryParams = request.uri.queryParameters
        guard let id = queryParams["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        // Optional status in body or query param
        let runStatus = (try? await request.decode(as: ExecutedCalendarBody.self, context: context))?.status
            ?? queryParams["status"].map(String.init)
            ?? "success"

        let now = nowMs()

        do {
            try await dbPool.write { db in
                // Fetch current row to get recurrence and scheduledAt
                let row = try CalendarEventRow.fetchOne(db, sql: "SELECT * FROM calendarEvents WHERE id = ?", arguments: [id])
                guard let row else {
                    return  // silently skip if not found — caller gets success anyway
                }

                var newScheduledAt = row.scheduledAt
                if let recurrence = row.recurrence, !recurrence.isEmpty {
                    newScheduledAt = advanceSchedule(row.scheduledAt, by: recurrence)
                    // If the advanced time is still in the past, keep advancing
                    while newScheduledAt <= now {
                        newScheduledAt = advanceSchedule(newScheduledAt, by: recurrence)
                    }
                }

                try db.execute(
                    sql: """
                    UPDATE calendarEvents
                    SET lastRunAt = ?, lastRunStatus = ?, runCount = runCount + 1,
                        scheduledAt = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [now, runStatus, newScheduledAt, now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }
}
