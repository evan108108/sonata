import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct ScheduledJobRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "scheduledJobs"

    var id: String
    var name: String
    var schedule: String
    var command: String
    var enabled: Bool
    var lastRunAt: Double?
    var lastResult: String?
    var lastError: String?
    var lastExitCode: Double?
    var nextRunAt: Double?
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, schedule, command, enabled
        case lastRunAt, lastResult, lastError, lastExitCode
        case nextRunAt, createdAt
    }
}

// MARK: - Request Bodies

struct UpsertScheduledJobRequest: Decodable {
    let name: String
    let schedule: String
    let command: String
    let enabled: Bool?
    let nextRunAt: Double?
}

struct MarkRunRequest: Decodable {
    let lastResult: String?
    let lastExitCode: Double?
    let lastError: String?
}

// MARK: - Response Types

struct ScheduledJobResponse: Encodable {
    let _id: String
    let name: String
    let schedule: String
    let command: String
    let enabled: Bool
    let lastRunAt: Double?
    let lastResult: String?
    let lastError: String?
    let lastExitCode: Double?
    let nextRunAt: Double?
    let createdAt: Double
}

// MARK: - Helpers

private func jobToResponse(_ row: ScheduledJobRow) -> ScheduledJobResponse {
    ScheduledJobResponse(
        _id: row.id,
        name: row.name,
        schedule: row.schedule,
        command: row.command,
        enabled: row.enabled,
        lastRunAt: row.lastRunAt,
        lastResult: row.lastResult,
        lastError: row.lastError,
        lastExitCode: row.lastExitCode,
        nextRunAt: row.nextRunAt,
        createdAt: row.createdAt
    )
}

/// Compute the next run time (in epoch ms) using CronParser.
private func computeNextRunAt(schedule: String, after: Double) -> Double? {
    let afterDate = Date(timeIntervalSince1970: after / 1000.0)
    guard let parsed = CronParser.parse(schedule) else { return nil }
    let next = CronParser.nextFire(for: parsed, after: afterDate)
    return next.timeIntervalSince1970 * 1000.0
}

// MARK: - Route Registration

public func registerScheduledJobRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool,
    scheduler: SchedulerActor? = nil
) {
    let api = router.group("/api/cron")

    // GET /api/cron/list — all scheduled jobs
    api.get("/list") { _, _ -> Response in
        do {
            let rows = try await dbPool.read { db in
                try ScheduledJobRow.fetchAll(db, sql: "SELECT * FROM scheduledJobs ORDER BY name ASC")
            }
            return jsonResponse(rows.map(jobToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/cron — create/update (upsert by name)
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: UpsertScheduledJobRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.name.isEmpty, !body.schedule.isEmpty, !body.command.isEmpty else {
            return errorResponse("name, schedule, and command are required")
        }

        let now = Double(nowMs())
        let enabled = body.enabled ?? true
        let nextRun = body.nextRunAt ?? computeNextRunAt(schedule: body.schedule, after: now) ?? (now + 60_000)

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO scheduledJobs (id, name, schedule, command, enabled, nextRunAt, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        schedule = excluded.schedule,
                        command = excluded.command,
                        enabled = excluded.enabled,
                        nextRunAt = excluded.nextRunAt
                    """,
                    arguments: [newUUID(), body.name, body.schedule, body.command,
                               enabled, nextRun, now]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        if let scheduler = scheduler { await scheduler.reload() }
        return jsonResponse(SuccessResponse(), status: .created)
    }

    // DELETE /api/cron?name= — delete by name
    api.delete("/") { request, _ -> Response in
        guard let name = request.uri.queryParameters["name"].map(String.init), !name.isEmpty else {
            return errorResponse("name parameter is required")
        }

        do {
            try await dbPool.write { db in
                try db.execute(sql: "DELETE FROM scheduledJobs WHERE name = ?", arguments: [name])
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        if let scheduler = scheduler { await scheduler.reload() }
        return jsonResponse(SuccessResponse())
    }

    // GET /api/cron/due — jobs where enabled=true AND nextRunAt <= now
    api.get("/due") { _, _ -> Response in
        let now = Double(nowMs())

        do {
            let rows = try await dbPool.read { db in
                try ScheduledJobRow.fetchAll(db,
                    sql: "SELECT * FROM scheduledJobs WHERE enabled = 1 AND nextRunAt <= ? ORDER BY nextRunAt ASC",
                    arguments: [now]
                )
            }
            return jsonResponse(rows.map(jobToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/cron/mark-run?name= — update lastRunAt, lastResult, lastExitCode, compute nextRunAt
    api.post("/mark-run") { request, context -> Response in
        guard let name = request.uri.queryParameters["name"].map(String.init), !name.isEmpty else {
            return errorResponse("name parameter is required")
        }

        let body = try? await request.decode(as: MarkRunRequest.self, context: context)
        let now = Double(nowMs())

        do {
            try await dbPool.write { db in
                // Fetch current job to get schedule
                guard let job = try ScheduledJobRow.fetchOne(db,
                    sql: "SELECT * FROM scheduledJobs WHERE name = ?",
                    arguments: [name]
                ) else {
                    return
                }

                let nextRun = computeNextRunAt(schedule: job.schedule, after: now) ?? (now + 60_000)

                try db.execute(
                    sql: """
                    UPDATE scheduledJobs
                    SET lastRunAt = ?, lastResult = ?, lastExitCode = ?, lastError = ?, nextRunAt = ?
                    WHERE name = ?
                    """,
                    arguments: [now, body?.lastResult, body?.lastExitCode, body?.lastError, nextRun, name]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/cron/trigger?name= — fire immediately via scheduler
    api.post("/trigger") { request, _ -> Response in
        guard let name = request.uri.queryParameters["name"].map(String.init), !name.isEmpty else {
            return errorResponse("name parameter is required")
        }

        // Look up the job ID by name
        let jobId: String? = try? await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM scheduledJobs WHERE name = ?", arguments: [name])
        }

        guard let id = jobId else {
            return errorResponse("Job not found: \(name)", status: .notFound)
        }

        if let scheduler = scheduler {
            await scheduler.triggerNow(jobId: id)
        }

        return jsonResponse(SuccessResponse())
    }

    // GET /api/scheduler/queue — expose the in-memory scheduler queue
    router.get("/api/scheduler/queue") { _, _ -> Response in
        guard let scheduler = scheduler else {
            return errorResponse("Scheduler not available", status: .serviceUnavailable)
        }

        let entries = await scheduler.status()
        let iso = ISO8601DateFormatter()
        let result = entries.map { entry in
            [
                "id": entry.id,
                "name": entry.name,
                "type": entry.type,
                "nextFire": iso.string(from: entry.nextFire)
            ]
        }
        return jsonResponse(result)
    }
}
