import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/calendar routes.
// Handler logic is duplicated from CalendarRoutes.swift.
//
// Note: scheduler.reload() / scheduler.triggerNow() side-effects from the
// original routes are omitted here — SchedulerActor isn't reachable through
// ActionContext. They'll be wired up in Phase 3 when actions replace routes.

private func rowToCalendarResponseForAction(_ row: CalendarEventRow) -> CalendarEventResponse {
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
private func advanceScheduleForAction(_ scheduledAt: Int64, by recurrence: String) -> Int64 {
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
        return scheduledAt + msPerDay
    }
}

let calendarActions: [SonataAction] = [

    // GET /api/calendar/upcoming — enabled events with scheduledAt > now
    SonataAction(
        name: "calendar_upcoming",
        description: "Upcoming enabled calendar events (scheduledAt > now).",
        group: "/api/calendar",
        path: "/upcoming",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 50)"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 50
            let now = nowMs()
            do {
                let rows = try await ctx.dbPool.read { db in
                    try CalendarEventRow.fetchAll(db, sql: """
                        SELECT * FROM calendarEvents
                        WHERE enabled = 1 AND scheduledAt > ?
                        ORDER BY scheduledAt ASC LIMIT ?
                    """, arguments: [now, limit])
                }
                return rows.map(rowToCalendarResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/calendar/all — all events
    SonataAction(
        name: "calendar_all",
        description: "All calendar events ordered by scheduledAt DESC.",
        group: "/api/calendar",
        path: "/all",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 100)"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 100
            do {
                let rows = try await ctx.dbPool.read { db in
                    try CalendarEventRow.fetchAll(db, sql: """
                        SELECT * FROM calendarEvents
                        ORDER BY scheduledAt DESC LIMIT ?
                    """, arguments: [limit])
                }
                return rows.map(rowToCalendarResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/calendar/due — enabled events where scheduledAt <= now
    SonataAction(
        name: "calendar_due",
        description: "Due calendar events (enabled, scheduledAt <= now).",
        group: "/api/calendar",
        path: "/due",
        method: .get,
        params: [],
        handler: { ctx in
            let now = nowMs()
            do {
                let rows = try await ctx.dbPool.read { db in
                    try CalendarEventRow.fetchAll(db, sql: """
                        SELECT * FROM calendarEvents
                        WHERE enabled = 1 AND scheduledAt <= ?
                        ORDER BY scheduledAt ASC
                    """, arguments: [now])
                }
                return rows.map(rowToCalendarResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/calendar — create event
    SonataAction(
        name: "calendar_create",
        description: "Create a calendar event.",
        group: "/api/calendar",
        path: "/",
        method: .post,
        params: [
            ActionParam("title", .string, required: true, description: "Event title"),
            ActionParam("description", .string, description: "Event description"),
            ActionParam("prompt", .string, description: "Task prompt for the run"),
            ActionParam("scheduledAt", .integer, required: true, description: "Scheduled at (epoch ms)"),
            ActionParam("recurrence", .string, description: "Recurrence string"),
            ActionParam("enabled", .boolean, description: "Enabled (default true)"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("workingDir", .string, description: "Working directory"),
            ActionParam("model", .string, description: "Model override"),
            ActionParam("maxTurns", .integer, description: "Max turns override"),
            ActionParam("taskType", .string, required: true, description: "Task type"),
        ],
        handler: { ctx in
            let title = try ctx.params.require("title")
            let scheduledAt = Int64(try ctx.params.requireInt("scheduledAt"))
            let taskType = try ctx.params.require("taskType")
            let description = ctx.params.string("description")
            let prompt = ctx.params.string("prompt")
            let recurrence = ctx.params.string("recurrence")
            let enabled = (ctx.params.bool("enabled") ?? true) ? 1 : 0
            let project = ctx.params.string("project")
            let workingDir = ctx.params.string("workingDir")
            let model = ctx.params.string("model")
            let maxTurns = ctx.params.int("maxTurns")

            let id = newUUID()
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO calendarEvents
                            (id, title, description, prompt, scheduledAt, recurrence,
                             runCount, enabled, project, workingDir, model, maxTurns,
                             taskType, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            id, title, description, prompt,
                            scheduledAt, recurrence,
                            enabled, project, workingDir,
                            model, maxTurns, taskType,
                            now, now
                        ]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // PATCH /api/calendar — update event
    SonataAction(
        name: "calendar_update",
        description: "Partial update of a calendar event by id.",
        group: "/api/calendar",
        path: "/",
        method: .patch,
        params: [
            ActionParam("id", .string, required: true, description: "Event id"),
            ActionParam("title", .string, description: "New title"),
            ActionParam("description", .string, description: "New description"),
            ActionParam("prompt", .string, description: "New prompt"),
            ActionParam("scheduledAt", .integer, description: "New scheduledAt (epoch ms)"),
            ActionParam("recurrence", .string, description: "New recurrence"),
            ActionParam("enabled", .boolean, description: "Enable/disable"),
            ActionParam("project", .string, description: "New project"),
            ActionParam("workingDir", .string, description: "New working dir"),
            ActionParam("model", .string, description: "New model"),
            ActionParam("maxTurns", .integer, description: "New max turns"),
            ActionParam("taskType", .string, description: "New task type"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")

            let now = nowMs()
            var setClauses: [String] = ["updatedAt = ?"]
            var args: [any DatabaseValueConvertible] = [now]

            if let v = ctx.params.string("title")       { setClauses.append("title = ?");       args.append(v) }
            if let v = ctx.params.string("description") { setClauses.append("description = ?"); args.append(v) }
            if let v = ctx.params.string("prompt")      { setClauses.append("prompt = ?");      args.append(v) }
            if let v = ctx.params.int("scheduledAt")    { setClauses.append("scheduledAt = ?"); args.append(Int64(v)) }
            if let v = ctx.params.string("recurrence")  { setClauses.append("recurrence = ?");  args.append(v) }
            if let v = ctx.params.bool("enabled")       { setClauses.append("enabled = ?");     args.append(v ? 1 : 0) }
            if let v = ctx.params.string("project")     { setClauses.append("project = ?");     args.append(v) }
            if let v = ctx.params.string("workingDir")  { setClauses.append("workingDir = ?");  args.append(v) }
            if let v = ctx.params.string("model")       { setClauses.append("model = ?");       args.append(v) }
            if let v = ctx.params.int("maxTurns")       { setClauses.append("maxTurns = ?");    args.append(v) }
            if let v = ctx.params.string("taskType")    { setClauses.append("taskType = ?");    args.append(v) }

            args.append(id)
            let sql = "UPDATE calendarEvents SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: sql, arguments: StatementArguments(args))
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return PatchResponse(id: id)
        }
    ),

    // DELETE /api/calendar?id=
    SonataAction(
        name: "calendar_delete",
        description: "Delete a calendar event by id.",
        group: "/api/calendar",
        path: "/",
        method: .delete,
        params: [
            ActionParam("id", .string, required: true, description: "Event id"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM calendarEvents WHERE id = ?", arguments: [id])
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/calendar/enable?id=
    SonataAction(
        name: "calendar_enable",
        description: "Enable a calendar event by id.",
        group: "/api/calendar",
        path: "/enable",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Event id", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE calendarEvents SET enabled = 1, updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/calendar/disable?id=
    SonataAction(
        name: "calendar_disable",
        description: "Disable a calendar event by id.",
        group: "/api/calendar",
        path: "/disable",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Event id", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE calendarEvents SET enabled = 0, updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/calendar/executed?id= — update run stats, advance scheduledAt
    SonataAction(
        name: "calendar_executed",
        description: "Mark a calendar event executed: update lastRunAt/lastRunStatus, increment runCount, advance scheduledAt per recurrence.",
        group: "/api/calendar",
        path: "/executed",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Event id", source: .query),
            ActionParam("status", .string, description: "Run status (default 'success')"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let runStatus = ctx.params.string("status") ?? "success"
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    guard let row = try CalendarEventRow.fetchOne(
                        db, sql: "SELECT * FROM calendarEvents WHERE id = ?", arguments: [id]
                    ) else {
                        return
                    }

                    var newScheduledAt = row.scheduledAt
                    if let recurrence = row.recurrence, !recurrence.isEmpty {
                        newScheduledAt = advanceScheduleForAction(row.scheduledAt, by: recurrence)
                        while newScheduledAt <= now {
                            newScheduledAt = advanceScheduleForAction(newScheduledAt, by: recurrence)
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
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/calendar/trigger?id=
    // Original route fires the event via SchedulerActor.triggerNow. Without
    // scheduler injection (see file header note) this is a no-op acknowledgement.
    SonataAction(
        name: "calendar_trigger",
        description: "Trigger a calendar event to run immediately (via scheduler, when wired).",
        group: "/api/calendar",
        path: "/trigger",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Event id", source: .query),
        ],
        handler: { ctx in
            _ = try ctx.params.require("id")
            return SuccessResponse()
        }
    ),
]
