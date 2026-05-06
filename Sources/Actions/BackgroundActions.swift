import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/background-jobs routes.
// Handler logic duplicated from BackgroundRoutes.swift.
//
// Note: the /api/background/* manual trigger routes (consolidate, enrich, etc.)
// are intentionally NOT ported here — only the core job lifecycle endpoints.

private func backgroundJobToResponseForAction(_ row: BackgroundJobRow) -> BackgroundJobResponse {
    BackgroundJobResponse(
        _id: row.id,
        name: row.name,
        status: row.status,
        prompt: row.prompt,
        model: row.model,
        maxTurns: row.maxTurns,
        result: row.result,
        error: row.error,
        createdAt: row.createdAt,
        startedAt: row.startedAt,
        completedAt: row.completedAt
    )
}

let backgroundActions: [SonataAction] = [

    // GET /api/background-jobs — list jobs
    SonataAction(
        name: "background_list",
        description: "List background jobs, ordered by createdAt DESC.",
        group: "/api/background-jobs",
        path: "/",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 50)"),
            ActionParam("status", .string, description: "Filter by status"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 50
            let status = ctx.params.string("status")

            var sql = "SELECT * FROM backgroundJobs WHERE 1=1"
            var args: [any DatabaseValueConvertible] = []

            if let s = status {
                sql += " AND status = ?"
                args.append(s)
            }
            sql += " ORDER BY createdAt DESC LIMIT ?"
            args.append(limit)

            do {
                let rows = try ctx.dbPool.read { db in
                    try BackgroundJobRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(backgroundJobToResponseForAction)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/background-jobs — create job
    SonataAction(
        name: "background_create",
        description: "Create a new background job in 'pending' status.",
        group: "/api/background-jobs",
        path: "/",
        method: .post,
        params: [
            ActionParam("name", .string, required: true, description: "Job name"),
            ActionParam("prompt", .string, required: true, description: "Job prompt"),
            ActionParam("model", .string, description: "Model override"),
            ActionParam("maxTurns", .integer, description: "Max turns override"),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            let prompt = try ctx.params.require("prompt")
            let model = ctx.params.string("model")
            let maxTurns = ctx.params.int("maxTurns")

            let now = nowMs()
            let id = newUUID()

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO backgroundJobs (id, name, status, prompt, model, maxTurns, createdAt)
                        VALUES (?, ?, 'pending', ?, ?, ?, ?)
                        """,
                        arguments: [id, name, prompt, model, maxTurns, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            return StoreResponse(id: id)
        }
    ),

    // POST /api/background-jobs/claim?id= — set running, startedAt
    SonataAction(
        name: "background_claim",
        description: "Claim a pending job: sets status='running' and startedAt.",
        group: "/api/background-jobs",
        path: "/claim",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Job ID", source: .query),
        ],
        httpOnly: true,
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE backgroundJobs SET status = 'running', startedAt = ? WHERE id = ? AND status = 'pending'",
                        arguments: [now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/background-jobs/complete?id= — set completed, result
    SonataAction(
        name: "background_complete",
        description: "Mark a job completed with optional result.",
        group: "/api/background-jobs",
        path: "/complete",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Job ID", source: .query),
            ActionParam("result", .string, description: "Job result"),
        ],
        httpOnly: true,
        handler: { ctx in
            let id = try ctx.params.require("id")
            let result = ctx.params.string("result")
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE backgroundJobs SET status = 'completed', result = ?, completedAt = ? WHERE id = ?",
                        arguments: [result, now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/background-jobs/fail?id= — set failed, error
    SonataAction(
        name: "background_fail",
        description: "Mark a job failed with an optional error message.",
        group: "/api/background-jobs",
        path: "/fail",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Job ID", source: .query),
            ActionParam("error", .string, description: "Error message"),
        ],
        httpOnly: true,
        handler: { ctx in
            let id = try ctx.params.require("id")
            let errorMsg = ctx.params.string("error")
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE backgroundJobs SET status = 'failed', error = ?, completedAt = ? WHERE id = ?",
                        arguments: [errorMsg, now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/background-jobs/timeout-stale — timeout running jobs older than 15min
    SonataAction(
        name: "background_timeout",
        description: "Timeout any 'running' job older than 15 minutes.",
        group: "/api/background-jobs",
        path: "/timeout-stale",
        method: .post,
        params: [],
        httpOnly: true,
        handler: { ctx in
            let cutoff = nowMs() - 15 * 60 * 1000  // 15 minutes
            let now = nowMs()

            do {
                let count = try await ctx.dbPool.write { db -> Int in
                    let before = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM backgroundJobs WHERE status = 'running' AND startedAt < ?",
                        arguments: [cutoff]
                    ) ?? 0

                    try db.execute(
                        sql: """
                        UPDATE backgroundJobs
                        SET status = 'failed', error = 'Timed out after 15 minutes', completedAt = ?
                        WHERE status = 'running' AND startedAt < ?
                        """,
                        arguments: [now, cutoff]
                    )
                    return before
                }
                return TimeoutResponse(timedOut: count)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/background-jobs/cleanup?retentionDays= — delete old completed/failed jobs
    SonataAction(
        name: "background_cleanup",
        description: "Delete completed/failed jobs older than retentionDays (default 7).",
        group: "/api/background-jobs",
        path: "/cleanup",
        method: .post,
        params: [
            ActionParam("retentionDays", .integer, description: "Retention window in days (default 7)"),
        ],
        httpOnly: true,
        handler: { ctx in
            let retentionDays = ctx.params.int("retentionDays") ?? 7
            let cutoff = nowMs() - Int64(retentionDays) * 86400 * 1000

            do {
                let count = try await ctx.dbPool.write { db -> Int in
                    let before = try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM backgroundJobs WHERE status IN ('completed', 'failed') AND completedAt < ?",
                        arguments: [cutoff]
                    ) ?? 0

                    try db.execute(
                        sql: "DELETE FROM backgroundJobs WHERE status IN ('completed', 'failed') AND completedAt < ?",
                        arguments: [cutoff]
                    )
                    return before
                }
                return CleanupResponse(deleted: count)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
