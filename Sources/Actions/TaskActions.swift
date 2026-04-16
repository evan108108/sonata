import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/task routes.
// Handler logic is duplicated from TaskRoutes.swift.

private let validTaskStatusesForActions: Set<String> = [
    "pending", "active", "completed", "failed", "cancelled"
]

private let validTaskPrioritiesForActions: Set<String> = [
    "critical", "high", "normal", "low", "backlog"
]

private func parseJSONStringArray(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else {
        return []
    }
    return arr
}

private func encodeJSONStringArray(_ arr: [String]) -> String {
    guard let data = try? JSONEncoder().encode(arr),
          let str = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return str
}

private func rowToTaskResp(_ row: TaskRow) -> TaskResponse {
    TaskResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        title: row.title,
        description: row.description,
        status: row.status,
        priority: row.priority,
        prompt: row.prompt,
        workingDir: row.workingDir,
        model: row.model,
        maxTurns: row.maxTurns,
        project: row.project,
        blockedBy: parseJSONStringArray(row.blockedBy),
        originalBlockedBy: parseJSONStringArray(row.originalBlockedBy),
        parentTask: row.parentTask,
        source: row.source,
        sourceRef: row.sourceRef,
        result: row.result,
        outputFiles: parseJSONStringArray(row.outputFiles),
        tags: parseJSONStringArray(row.tags),
        assignedTo: row.assignedTo,
        dueAt: row.dueAt,
        startedAt: row.startedAt,
        completedAt: row.completedAt,
        retryCount: row.retryCount,
        maxRetries: row.maxRetries,
        lastError: row.lastError,
        tools: parseJSONStringArray(row.tools),
        metadata: row.metadata,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

let taskActions: [SonataAction] = [

    // POST /api/task — create
    SonataAction(
        name: "mem_task_create",
        description: "Create a new task.",
        group: "/api/task",
        path: "/",
        method: .post,
        params: [
            ActionParam("title", .string, required: true, description: "Task title"),
            ActionParam("description", .string, description: "Task description"),
            ActionParam("status", .string, description: "Initial status (default 'pending')"),
            ActionParam("priority", .string, description: "Priority (default 'normal')"),
            ActionParam("prompt", .string, description: "Prompt/instructions for the worker"),
            ActionParam("workingDir", .string, description: "Working directory"),
            ActionParam("model", .string, description: "Model override"),
            ActionParam("maxTurns", .integer, description: "Max turns"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("blockedBy", .stringArray, description: "Blocker task IDs"),
            ActionParam("parentTask", .string, description: "Parent task ID"),
            ActionParam("source", .string, required: true, description: "Source system"),
            ActionParam("sourceRef", .string, description: "External source reference"),
            ActionParam("tags", .stringArray, description: "Tags"),
            ActionParam("assignedTo", .string, description: "Assignee"),
            ActionParam("dueAt", .integer, description: "Due timestamp (epoch ms)"),
            ActionParam("maxRetries", .integer, description: "Max retries"),
            ActionParam("tools", .stringArray, description: "Allowed tools"),
            ActionParam("metadata", .string, description: "JSON metadata string"),
        ],
        handler: { ctx in
            let title = try ctx.params.require("title")
            let source = try ctx.params.require("source")
            let status = ctx.params.string("status") ?? "pending"
            guard validTaskStatusesForActions.contains(status) else {
                throw ActionError.invalidParam("status", "Invalid status '\(status)'")
            }
            let priority = ctx.params.string("priority") ?? "normal"
            guard validTaskPrioritiesForActions.contains(priority) else {
                throw ActionError.invalidParam("priority", "Invalid priority '\(priority)'")
            }

            let now = nowMs()
            let id = newUUID()
            let blockedByJSON = encodeJSONStringArray(ctx.params.stringArray("blockedBy") ?? [])
            let tagsJSON = encodeTags(ctx.params.stringArray("tags") ?? [])
            let toolsJSON = encodeJSONStringArray(ctx.params.stringArray("tools") ?? [])

            let description = ctx.params.string("description")
            let prompt = ctx.params.string("prompt")
            let workingDir = ctx.params.string("workingDir")
            let model = ctx.params.string("model")
            let maxTurns = ctx.params.int("maxTurns")
            let project = ctx.params.string("project")
            let parentTask = ctx.params.string("parentTask")
            let sourceRef = ctx.params.string("sourceRef")
            let assignedTo = ctx.params.string("assignedTo")
            let dueAt = ctx.params.int("dueAt").map { Int64($0) }
            let maxRetries = ctx.params.int("maxRetries")
            let metadata = ctx.params.string("metadata")

            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO tasks
                            (id, title, description, status, priority,
                             prompt, workingDir, model, maxTurns,
                             project, blockedBy, originalBlockedBy, parentTask,
                             source, sourceRef, tags, assignedTo, dueAt,
                             maxRetries, tools, metadata,
                             retryCount, outputFiles,
                             createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?,
                                ?, ?, ?, ?,
                                ?, ?, ?, ?,
                                ?, ?, ?, ?, ?,
                                ?, ?, ?,
                                0, '[]',
                                ?, ?)
                        """,
                        arguments: [
                            id, title, description, status, priority,
                            prompt, workingDir, model, maxTurns,
                            project, blockedByJSON, blockedByJSON, parentTask,
                            source, sourceRef, tagsJSON, assignedTo, dueAt,
                            maxRetries, toolsJSON, metadata,
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

    // GET /api/task/list
    SonataAction(
        name: "mem_task_list",
        description: "List tasks with filters.",
        group: "/api/task",
        path: "/list",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 50)"),
            ActionParam("status", .string, description: "Filter by status"),
            ActionParam("project", .string, description: "Filter by project"),
            ActionParam("assignedTo", .string, description: "Filter by assignee"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 50
            let status = ctx.params.string("status")
            let project = ctx.params.string("project")
            let assignedTo = ctx.params.string("assignedTo")

            var sql = "SELECT * FROM tasks WHERE 1=1"
            var args: [any DatabaseValueConvertible] = []

            if let s = status {
                sql += " AND status = ?"
                args.append(s)
            }
            if let p = project {
                sql += " AND project = ?"
                args.append(p)
            }
            if let a = assignedTo {
                sql += " AND assignedTo = ?"
                args.append(a)
            }
            sql += " ORDER BY createdAt DESC LIMIT ?"
            args.append(limit)

            do {
                let rows = try await ctx.dbPool.read { db in
                    try TaskRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(rowToTaskResp)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/task/get?id=
    SonataAction(
        name: "mem_task_get",
        description: "Get a task by ID.",
        group: "/api/task",
        path: "/get",
        method: .get,
        params: [
            ActionParam("id", .string, required: true, description: "Task ID"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            do {
                let row = try await ctx.dbPool.read { db in
                    try TaskRow.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id])
                }
                guard let row else {
                    throw ActionError.notFound("Task not found")
                }
                return rowToTaskResp(row)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/task/search?q=
    SonataAction(
        name: "mem_task_search",
        description: "Full-text search on tasks (FTS5 on title).",
        group: "/api/task",
        path: "/search",
        method: .get,
        params: [
            ActionParam("q", .string, required: true, description: "FTS5 query string"),
            ActionParam("limit", .integer, description: "Max results (default 20)"),
        ],
        handler: { ctx in
            let q = try ctx.params.require("q")
            let limit = ctx.params.int("limit") ?? 20

            do {
                let rows = try await ctx.dbPool.read { db in
                    try TaskRow.fetchAll(db, sql: """
                        SELECT t.* FROM tasks t
                        JOIN tasks_fts fts ON fts.rowid = t.rowid
                        WHERE tasks_fts MATCH ?
                        ORDER BY t.createdAt DESC LIMIT ?
                    """, arguments: [q, limit])
                }
                return rows.map(rowToTaskResp)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/task/actionable
    SonataAction(
        name: "mem_task_actionable",
        description: "List pending tasks with no unresolved blockers, sorted by priority.",
        group: "/api/task",
        path: "/actionable",
        method: .get,
        params: [
            ActionParam("limit", .integer, description: "Max results (default 50)"),
            ActionParam("assignedTo", .string, description: "Filter by assignee"),
        ],
        handler: { ctx in
            let limit = ctx.params.int("limit") ?? 50
            let assignedTo = ctx.params.string("assignedTo")

            var sql = """
                SELECT * FROM tasks
                WHERE status = 'pending'
                AND (blockedBy IS NULL OR blockedBy = '[]')
            """
            var args: [any DatabaseValueConvertible] = []

            if let a = assignedTo {
                sql += " AND assignedTo = ?"
                args.append(a)
            }
            sql += " ORDER BY CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 WHEN 'low' THEN 3 WHEN 'backlog' THEN 4 END, createdAt ASC LIMIT ?"
            args.append(limit)

            do {
                let rows = try await ctx.dbPool.read { db in
                    try TaskRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
                return rows.map(rowToTaskResp)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // PATCH /api/task
    SonataAction(
        name: "mem_task_patch",
        description: "Update any fields on a task by ID.",
        group: "/api/task",
        path: "/",
        method: .patch,
        params: [
            ActionParam("id", .string, required: true, description: "Task ID"),
            ActionParam("title", .string),
            ActionParam("description", .string),
            ActionParam("status", .string),
            ActionParam("priority", .string),
            ActionParam("prompt", .string),
            ActionParam("workingDir", .string),
            ActionParam("model", .string),
            ActionParam("maxTurns", .integer),
            ActionParam("project", .string),
            ActionParam("blockedBy", .stringArray),
            ActionParam("originalBlockedBy", .stringArray),
            ActionParam("parentTask", .string),
            ActionParam("source", .string),
            ActionParam("sourceRef", .string),
            ActionParam("result", .string),
            ActionParam("outputFiles", .stringArray),
            ActionParam("tags", .stringArray),
            ActionParam("assignedTo", .string),
            ActionParam("dueAt", .integer),
            ActionParam("startedAt", .integer),
            ActionParam("completedAt", .integer),
            ActionParam("retryCount", .integer),
            ActionParam("maxRetries", .integer),
            ActionParam("lastError", .string),
            ActionParam("tools", .stringArray),
            ActionParam("metadata", .string),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            if let s = ctx.params.string("status"), !validTaskStatusesForActions.contains(s) {
                throw ActionError.invalidParam("status", "Invalid status '\(s)'")
            }
            if let p = ctx.params.string("priority"), !validTaskPrioritiesForActions.contains(p) {
                throw ActionError.invalidParam("priority", "Invalid priority '\(p)'")
            }

            let now = nowMs()
            var setClauses: [String] = ["updatedAt = ?"]
            var args: [any DatabaseValueConvertible] = [now]

            if let v = ctx.params.string("title")       { setClauses.append("title = ?");       args.append(v) }
            if let v = ctx.params.string("description") { setClauses.append("description = ?"); args.append(v) }
            if let v = ctx.params.string("status")      { setClauses.append("status = ?");      args.append(v) }
            if let v = ctx.params.string("priority")    { setClauses.append("priority = ?");    args.append(v) }
            if let v = ctx.params.string("prompt")      { setClauses.append("prompt = ?");      args.append(v) }
            if let v = ctx.params.string("workingDir")  { setClauses.append("workingDir = ?");  args.append(v) }
            if let v = ctx.params.string("model")       { setClauses.append("model = ?");       args.append(v) }
            if let v = ctx.params.int("maxTurns")       { setClauses.append("maxTurns = ?");    args.append(v) }
            if let v = ctx.params.string("project")     { setClauses.append("project = ?");     args.append(v) }
            if let v = ctx.params.stringArray("blockedBy")         { setClauses.append("blockedBy = ?");         args.append(encodeJSONStringArray(v)) }
            if let v = ctx.params.stringArray("originalBlockedBy") { setClauses.append("originalBlockedBy = ?"); args.append(encodeJSONStringArray(v)) }
            if let v = ctx.params.string("parentTask")  { setClauses.append("parentTask = ?");  args.append(v) }
            if let v = ctx.params.string("source")      { setClauses.append("source = ?");      args.append(v) }
            if let v = ctx.params.string("sourceRef")   { setClauses.append("sourceRef = ?");   args.append(v) }
            if let v = ctx.params.string("result")      { setClauses.append("result = ?");      args.append(v) }
            if let v = ctx.params.stringArray("outputFiles") { setClauses.append("outputFiles = ?"); args.append(encodeJSONStringArray(v)) }
            if let v = ctx.params.stringArray("tags")        { setClauses.append("tags = ?");        args.append(encodeTags(v)) }
            if let v = ctx.params.string("assignedTo")  { setClauses.append("assignedTo = ?");  args.append(v) }
            if let v = ctx.params.int("dueAt")          { setClauses.append("dueAt = ?");       args.append(Int64(v)) }
            if let v = ctx.params.int("startedAt")      { setClauses.append("startedAt = ?");   args.append(Int64(v)) }
            if let v = ctx.params.int("completedAt")    { setClauses.append("completedAt = ?"); args.append(Int64(v)) }
            if let v = ctx.params.int("retryCount")     { setClauses.append("retryCount = ?");  args.append(v) }
            if let v = ctx.params.int("maxRetries")     { setClauses.append("maxRetries = ?");  args.append(v) }
            if let v = ctx.params.string("lastError")   { setClauses.append("lastError = ?");   args.append(v) }
            if let v = ctx.params.stringArray("tools")  { setClauses.append("tools = ?");       args.append(encodeJSONStringArray(v)) }
            if let v = ctx.params.string("metadata")    { setClauses.append("metadata = ?");    args.append(v) }

            args.append(id)
            let sql = "UPDATE tasks SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

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

    // POST /api/task/complete?id=
    SonataAction(
        name: "mem_task_complete",
        description: "Mark a task completed and unblock dependents.",
        group: "/api/task",
        path: "/complete",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Task ID", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        UPDATE tasks
                        SET status = 'completed', completedAt = ?, updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [now, now, id]
                    )
                    try unblockDependents(taskId: id, in: db, now: now)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/task/fail?id=
    SonataAction(
        name: "mem_task_fail",
        description: "Mark a task failed, optionally setting lastError.",
        group: "/api/task",
        path: "/fail",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Task ID", source: .query),
            ActionParam("lastError", .string, description: "Error message"),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let lastError = ctx.params.string("lastError")
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    var sql = "UPDATE tasks SET status = 'failed', updatedAt = ?"
                    var args: [any DatabaseValueConvertible] = [now]
                    if let err = lastError {
                        sql += ", lastError = ?"
                        args.append(err)
                    }
                    sql += " WHERE id = ?"
                    args.append(id)
                    try db.execute(sql: sql, arguments: StatementArguments(args))
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/task/cancel?id=
    SonataAction(
        name: "mem_task_cancel",
        description: "Mark a task cancelled.",
        group: "/api/task",
        path: "/cancel",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Task ID", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE tasks SET status = 'cancelled', updatedAt = ? WHERE id = ?",
                        arguments: [now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/task/activate?id=
    SonataAction(
        name: "mem_task_activate",
        description: "Mark a task active, setting startedAt=now.",
        group: "/api/task",
        path: "/activate",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Task ID", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        UPDATE tasks
                        SET status = 'active', startedAt = ?, updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [now, now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // POST /api/task/retry?id=
    SonataAction(
        name: "mem_task_retry",
        description: "Increment retryCount and set a task back to 'pending'.",
        group: "/api/task",
        path: "/retry",
        method: .post,
        params: [
            ActionParam("id", .string, required: true, description: "Task ID", source: .query),
        ],
        handler: { ctx in
            let id = try ctx.params.require("id")
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        UPDATE tasks
                        SET status = 'pending',
                            retryCount = retryCount + 1,
                            updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [now, id]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return SuccessResponse()
        }
    ),

    // GET /api/task/subtasks?parentId=
    SonataAction(
        name: "mem_task_subtasks",
        description: "List direct subtasks by parentId.",
        group: "/api/task",
        path: "/subtasks",
        method: .get,
        params: [
            ActionParam("parentId", .string, required: true, description: "Parent task ID"),
        ],
        handler: { ctx in
            let parentId = try ctx.params.require("parentId")
            do {
                let rows = try await ctx.dbPool.read { db in
                    try TaskRow.fetchAll(db, sql: """
                        SELECT * FROM tasks
                        WHERE parentTask = ?
                        ORDER BY createdAt ASC
                    """, arguments: [parentId])
                }
                return rows.map(rowToTaskResp)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/task/stats
    SonataAction(
        name: "mem_task_stats",
        description: "Count tasks by status.",
        group: "/api/task",
        path: "/stats",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let stats = try await ctx.dbPool.read { db -> TaskStatsResponse in
                    var counts: [String: Int] = [:]
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT status, COUNT(*) as cnt FROM tasks GROUP BY status
                    """)
                    for row in rows {
                        let s: String = row["status"]
                        let c: Int = row["cnt"]
                        counts[s] = c
                    }
                    let total = counts.values.reduce(0, +)
                    return TaskStatsResponse(
                        pending: counts["pending"] ?? 0,
                        active: counts["active"] ?? 0,
                        completed: counts["completed"] ?? 0,
                        failed: counts["failed"] ?? 0,
                        cancelled: counts["cancelled"] ?? 0,
                        total: total
                    )
                }
                return stats
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
