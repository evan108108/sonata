import Foundation
import GRDB
import Hummingbird

// Action definitions for /api/cron + /api/scheduler routes.
// Scheduler side-effects (triggerNow, status) are wired via ctx.scheduler when set.

private struct SchedulerQueueEntry: Encodable {
    let id: String
    let name: String
    let type: String
    let nextFire: String
}

private func jobToResponseForAction(_ row: ScheduledJobRow) -> ScheduledJobResponse {
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

/// Compute next cron fire time (epoch ms) using CronParser.
private func computeNextRunAtForAction(schedule: String, after: Double) -> Double? {
    let afterDate = Date(timeIntervalSince1970: after / 1000.0)
    guard let parsed = CronParser.parse(schedule) else { return nil }
    let next = CronParser.nextFire(for: parsed, after: afterDate)
    return next.timeIntervalSince1970 * 1000.0
}

let schedulerActions: [SonataAction] = [

    // GET /api/cron/list
    SonataAction(
        name: "scheduler_list",
        description: "List all scheduled cron jobs ordered by name.",
        group: "/api/cron",
        path: "/list",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let rows = try await ctx.dbPool.read { db in
                    try ScheduledJobRow.fetchAll(db, sql: "SELECT * FROM scheduledJobs ORDER BY name ASC")
                }
                return rows.map(jobToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/cron — upsert by name
    SonataAction(
        name: "scheduler_create",
        description: "Create or update (upsert by name) a scheduled cron job.",
        group: "/api/cron",
        path: "/",
        method: .post,
        params: [
            ActionParam("name", .string, required: true, description: "Unique job name"),
            ActionParam("schedule", .string, required: true, description: "Cron expression"),
            ActionParam("command", .string, required: true, description: "Command to run"),
            ActionParam("enabled", .boolean, description: "Enabled (default true)"),
            ActionParam("nextRunAt", .number, description: "Override nextRunAt (epoch ms)"),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            let schedule = try ctx.params.require("schedule")
            let command = try ctx.params.require("command")
            let enabled = ctx.params.bool("enabled") ?? true

            let now = Double(nowMs())
            let nextRun = ctx.params.double("nextRunAt")
                ?? computeNextRunAtForAction(schedule: schedule, after: now)
                ?? (now + 60_000)

            do {
                try await ctx.dbPool.write { db in
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
                        arguments: [newUUID(), name, schedule, command,
                                   enabled, nextRun, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // DELETE /api/cron?name=
    SonataAction(
        name: "scheduler_delete",
        description: "Delete a scheduled cron job by name.",
        group: "/api/cron",
        path: "/",
        method: .delete,
        params: [
            ActionParam("name", .string, required: true, description: "Job name"),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM scheduledJobs WHERE name = ?", arguments: [name])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/cron/due — httpOnly, internal
    SonataAction(
        name: "scheduler_due",
        description: "Due scheduled jobs (enabled, nextRunAt <= now).",
        group: "/api/cron",
        path: "/due",
        method: .get,
        params: [],
        httpOnly: true,
        handler: { ctx in
            let now = Double(nowMs())
            do {
                let rows = try await ctx.dbPool.read { db in
                    try ScheduledJobRow.fetchAll(db,
                        sql: "SELECT * FROM scheduledJobs WHERE enabled = 1 AND nextRunAt <= ? ORDER BY nextRunAt ASC",
                        arguments: [now]
                    )
                }
                return rows.map(jobToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/cron/mark-run?name= — httpOnly, internal
    SonataAction(
        name: "scheduler_mark_run",
        description: "Mark a scheduled job as run: update lastRunAt/lastResult/lastExitCode/lastError and compute nextRunAt.",
        group: "/api/cron",
        path: "/mark-run",
        method: .post,
        params: [
            ActionParam("name", .string, required: true, description: "Job name", source: .query),
            ActionParam("lastResult", .string, description: "Run result"),
            ActionParam("lastExitCode", .number, description: "Exit code"),
            ActionParam("lastError", .string, description: "Error detail"),
        ],
        httpOnly: true,
        handler: { ctx in
            let name = try ctx.params.require("name")
            let lastResult = ctx.params.string("lastResult")
            let lastExitCode = ctx.params.double("lastExitCode")
            let lastError = ctx.params.string("lastError")

            let now = Double(nowMs())
            do {
                try await ctx.dbPool.write { db in
                    guard let job = try ScheduledJobRow.fetchOne(db,
                        sql: "SELECT * FROM scheduledJobs WHERE name = ?",
                        arguments: [name]
                    ) else {
                        return
                    }
                    let nextRun = computeNextRunAtForAction(schedule: job.schedule, after: now) ?? (now + 60_000)
                    try db.execute(
                        sql: """
                        UPDATE scheduledJobs
                        SET lastRunAt = ?, lastResult = ?, lastExitCode = ?, lastError = ?, nextRunAt = ?
                        WHERE name = ?
                        """,
                        arguments: [now, lastResult, lastExitCode, lastError, nextRun, name]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/cron/trigger?name=
    SonataAction(
        name: "scheduler_trigger",
        description: "Trigger a scheduled job immediately via SchedulerActor.",
        group: "/api/cron",
        path: "/trigger",
        method: .post,
        params: [
            ActionParam("name", .string, required: true, description: "Job name", source: .query),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            let jobId: String? = try? await ctx.dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT id FROM scheduledJobs WHERE name = ?", arguments: [name])
            }
            guard let id = jobId else {
                throw ActionError.notFound("Job not found: \(name)")
            }
            if let scheduler = ctx.scheduler {
                await scheduler.triggerNow(jobId: id)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/scheduler/queue
    SonataAction(
        name: "scheduler_queue",
        description: "Expose the in-memory scheduler queue from SchedulerActor.status().",
        group: "/api/scheduler",
        path: "/queue",
        method: .get,
        params: [],
        handler: { ctx in
            guard let scheduler = ctx.scheduler else {
                return [SchedulerQueueEntry]()
            }
            let entries = await scheduler.status()
            let iso = ISO8601DateFormatter()
            return entries.map { entry in
                SchedulerQueueEntry(
                    id: entry.id,
                    name: entry.name,
                    type: entry.type,
                    nextFire: iso.string(from: entry.nextFire)
                )
            }
        }
    ),
]
