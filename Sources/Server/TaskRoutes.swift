import Foundation
import Hummingbird
import GRDB

// MARK: - Valid Status & Priority

private let validTaskStatuses: Set<String> = [
    "pending", "active", "completed", "failed", "cancelled"
]

private let validTaskPriorities: Set<String> = [
    "critical", "high", "normal", "low", "backlog"
]

// MARK: - Database Row

struct TaskRow: FetchableRecord, Codable {
    static let databaseTableName = "tasks"

    var id: String
    var title: String
    var description: String?
    var status: String
    var priority: String
    var prompt: String?
    var workingDir: String?
    var model: String?
    var maxTurns: Int?
    var project: String?
    var blockedBy: String
    var originalBlockedBy: String
    var parentTask: String?
    var source: String
    var sourceRef: String?
    var result: String?
    var outputFiles: String
    var tags: String
    var assignedTo: String?
    var dueAt: Int64?
    var startedAt: Int64?
    var completedAt: Int64?
    var retryCount: Int
    var maxRetries: Int?
    var lastError: String?
    var tools: String
    var metadata: String?
    var createdAt: Int64
    var updatedAt: Int64
}

// MARK: - Request Bodies

struct CreateTaskRequest: Decodable {
    let title: String
    let description: String?
    let status: String?
    let priority: String?
    let prompt: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let project: String?
    let blockedBy: [String]?
    let parentTask: String?
    let source: String
    let sourceRef: String?
    let tags: [String]?
    let assignedTo: String?
    let dueAt: Int64?
    let maxRetries: Int?
    let tools: [String]?
    let metadata: String?
}

struct PatchTaskRequest: Decodable {
    let id: String
    let title: String?
    let description: String?
    let status: String?
    let priority: String?
    let prompt: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let project: String?
    let blockedBy: [String]?
    let originalBlockedBy: [String]?
    let parentTask: String?
    let source: String?
    let sourceRef: String?
    let result: String?
    let outputFiles: [String]?
    let tags: [String]?
    let assignedTo: String?
    let dueAt: Int64?
    let startedAt: Int64?
    let completedAt: Int64?
    let retryCount: Int?
    let maxRetries: Int?
    let lastError: String?
    let tools: [String]?
    let metadata: String?
}

struct TaskFailRequest: Decodable {
    let lastError: String?
}

// MARK: - Response

struct TaskResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let title: String
    let description: String?
    let status: String
    let priority: String
    let prompt: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let project: String?
    let blockedBy: [String]
    let originalBlockedBy: [String]
    let parentTask: String?
    let source: String
    let sourceRef: String?
    let result: String?
    let outputFiles: [String]
    let tags: [String]
    let assignedTo: String?
    let dueAt: Int64?
    let startedAt: Int64?
    let completedAt: Int64?
    let retryCount: Int
    let maxRetries: Int?
    let lastError: String?
    let tools: [String]
    let metadata: String?
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(status, forKey: .status)
        try c.encode(priority, forKey: .priority)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(workingDir, forKey: .workingDir)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(maxTurns, forKey: .maxTurns)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(blockedBy, forKey: .blockedBy)
        try c.encode(originalBlockedBy, forKey: .originalBlockedBy)
        try c.encodeIfPresent(parentTask, forKey: .parentTask)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sourceRef, forKey: .sourceRef)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encode(outputFiles, forKey: .outputFiles)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(assignedTo, forKey: .assignedTo)
        try c.encodeIfPresent(dueAt, forKey: .dueAt)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encode(retryCount, forKey: .retryCount)
        try c.encodeIfPresent(maxRetries, forKey: .maxRetries)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encode(tools, forKey: .tools)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case title, description, status, priority
        case prompt, workingDir, model, maxTurns
        case project, blockedBy, originalBlockedBy, parentTask
        case source, sourceRef, result, outputFiles
        case tags, assignedTo, dueAt, startedAt, completedAt
        case retryCount, maxRetries, lastError
        case tools, metadata, createdAt, updatedAt
    }
}

struct TaskStatsResponse: Encodable {
    let pending: Int
    let active: Int
    let completed: Int
    let failed: Int
    let cancelled: Int
    let total: Int
}

// MARK: - Helpers

private func parseJSONArray(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else {
        return []
    }
    return arr
}

private func encodeJSONArray(_ arr: [String]) -> String {
    guard let data = try? JSONEncoder().encode(arr),
          let str = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return str
}

private func rowToTaskResponse(_ row: TaskRow) -> TaskResponse {
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
        blockedBy: parseJSONArray(row.blockedBy),
        originalBlockedBy: parseJSONArray(row.originalBlockedBy),
        parentTask: row.parentTask,
        source: row.source,
        sourceRef: row.sourceRef,
        result: row.result,
        outputFiles: parseJSONArray(row.outputFiles),
        tags: parseJSONArray(row.tags),
        assignedTo: row.assignedTo,
        dueAt: row.dueAt,
        startedAt: row.startedAt,
        completedAt: row.completedAt,
        retryCount: row.retryCount,
        maxRetries: row.maxRetries,
        lastError: row.lastError,
        tools: parseJSONArray(row.tools),
        metadata: row.metadata,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

/// Remove `taskId` from the blockedBy JSON array of all tasks that reference it.
private func unblockDependents(taskId: String, db: Database) throws {
    // Find all tasks whose blockedBy array contains this taskId
    let rows = try TaskRow.fetchAll(db, sql: """
        SELECT * FROM tasks
        WHERE blockedBy LIKE ? AND status IN ('pending', 'active')
    """, arguments: ["%\(taskId)%"])

    for row in rows {
        var blocked = parseJSONArray(row.blockedBy)
        blocked.removeAll { $0 == taskId }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.execute(
            sql: "UPDATE tasks SET blockedBy = ?, updatedAt = ? WHERE id = ?",
            arguments: [encodeJSONArray(blocked), now, row.id]
        )
    }
}

// MARK: - Route Registration

public func registerTaskRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/task")

    // POST /api/task — create a new task
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: CreateTaskRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        let status = body.status ?? "pending"
        guard validTaskStatuses.contains(status) else {
            return errorResponse("Invalid status '\(status)'")
        }
        let priority = body.priority ?? "normal"
        guard validTaskPriorities.contains(priority) else {
            return errorResponse("Invalid priority '\(priority)'")
        }

        let now = nowMs()
        let id = newUUID()
        let blockedByJSON = encodeJSONArray(body.blockedBy ?? [])
        let tagsJSON = encodeTags(body.tags ?? [])
        let toolsJSON = encodeJSONArray(body.tools ?? [])

        do {
            try await dbPool.write { db in
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
                        id, body.title, body.description, status, priority,
                        body.prompt, body.workingDir, body.model, body.maxTurns,
                        body.project, blockedByJSON, blockedByJSON, body.parentTask,
                        body.source, body.sourceRef, tagsJSON, body.assignedTo, body.dueAt,
                        body.maxRetries, toolsJSON, body.metadata,
                        now, now
                    ]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(StoreResponse(id: id), status: .created)
    }

    // GET /api/task/list — list tasks with filters
    api.get("/list") { request, _ -> Response in
        let qp = request.uri.queryParameters
        let limit = Int(qp["limit"] ?? "") ?? 50
        let status = qp["status"].map(String.init)
        let project = qp["project"].map(String.init)
        let assignedTo = qp["assignedTo"].map(String.init)

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
            let rows = try await dbPool.read { db in
                try TaskRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(rowToTaskResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/task/get?id= — get single task
    api.get("/get") { request, _ -> Response in
        let qp = request.uri.queryParameters
        guard let id = qp["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        do {
            let row = try await dbPool.read { db in
                try TaskRow.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id])
            }
            guard let row else {
                return errorResponse("Task not found", status: .notFound)
            }
            return jsonResponse(rowToTaskResponse(row))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/task/search?q= — FTS5 search on title
    api.get("/search") { request, _ -> Response in
        let qp = request.uri.queryParameters
        guard let q = qp["q"].map(String.init), !q.isEmpty else {
            return errorResponse("Missing required query parameter 'q'")
        }
        let limit = Int(qp["limit"] ?? "") ?? 20

        do {
            let rows = try await dbPool.read { db in
                try TaskRow.fetchAll(db, sql: """
                    SELECT t.* FROM tasks t
                    JOIN tasks_fts fts ON fts.rowid = t.rowid
                    WHERE tasks_fts MATCH ?
                    ORDER BY t.createdAt DESC LIMIT ?
                """, arguments: [q, limit])
            }
            return jsonResponse(rows.map(rowToTaskResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/task/actionable — pending tasks where blockedBy is empty
    api.get("/actionable") { request, _ -> Response in
        let qp = request.uri.queryParameters
        let limit = Int(qp["limit"] ?? "") ?? 50
        let assignedTo = qp["assignedTo"].map(String.init)

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
            let rows = try await dbPool.read { db in
                try TaskRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(rowToTaskResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // PATCH /api/task — update any fields
    api.patch("/") { request, context -> Response in
        guard let body = try? await request.decode(as: PatchTaskRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.id.isEmpty else {
            return errorResponse("Missing id field")
        }
        if let s = body.status, !validTaskStatuses.contains(s) {
            return errorResponse("Invalid status '\(s)'")
        }
        if let p = body.priority, !validTaskPriorities.contains(p) {
            return errorResponse("Invalid priority '\(p)'")
        }

        let now = nowMs()
        var setClauses: [String] = ["updatedAt = ?"]
        var args: [any DatabaseValueConvertible] = [now]

        if let v = body.title           { setClauses.append("title = ?");           args.append(v) }
        if let v = body.description     { setClauses.append("description = ?");     args.append(v) }
        if let v = body.status          { setClauses.append("status = ?");          args.append(v) }
        if let v = body.priority        { setClauses.append("priority = ?");        args.append(v) }
        if let v = body.prompt          { setClauses.append("prompt = ?");          args.append(v) }
        if let v = body.workingDir      { setClauses.append("workingDir = ?");      args.append(v) }
        if let v = body.model           { setClauses.append("model = ?");           args.append(v) }
        if let v = body.maxTurns        { setClauses.append("maxTurns = ?");        args.append(v) }
        if let v = body.project         { setClauses.append("project = ?");         args.append(v) }
        if let v = body.blockedBy       { setClauses.append("blockedBy = ?");       args.append(encodeJSONArray(v)) }
        if let v = body.originalBlockedBy { setClauses.append("originalBlockedBy = ?"); args.append(encodeJSONArray(v)) }
        if let v = body.parentTask      { setClauses.append("parentTask = ?");      args.append(v) }
        if let v = body.source          { setClauses.append("source = ?");          args.append(v) }
        if let v = body.sourceRef       { setClauses.append("sourceRef = ?");       args.append(v) }
        if let v = body.result          { setClauses.append("result = ?");          args.append(v) }
        if let v = body.outputFiles     { setClauses.append("outputFiles = ?");     args.append(encodeJSONArray(v)) }
        if let v = body.tags            { setClauses.append("tags = ?");            args.append(encodeTags(v)) }
        if let v = body.assignedTo      { setClauses.append("assignedTo = ?");      args.append(v) }
        if let v = body.dueAt           { setClauses.append("dueAt = ?");           args.append(v as Int64) }
        if let v = body.startedAt       { setClauses.append("startedAt = ?");       args.append(v as Int64) }
        if let v = body.completedAt     { setClauses.append("completedAt = ?");     args.append(v as Int64) }
        if let v = body.retryCount      { setClauses.append("retryCount = ?");      args.append(v) }
        if let v = body.maxRetries      { setClauses.append("maxRetries = ?");      args.append(v) }
        if let v = body.lastError       { setClauses.append("lastError = ?");       args.append(v) }
        if let v = body.tools           { setClauses.append("tools = ?");           args.append(encodeJSONArray(v)) }
        if let v = body.metadata        { setClauses.append("metadata = ?");        args.append(v) }

        args.append(body.id)
        let sql = "UPDATE tasks SET \(setClauses.joined(separator: ", ")) WHERE id = ?"

        do {
            try await dbPool.write { db in
                try db.execute(sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(PatchResponse(id: body.id))
    }

    // POST /api/task/complete?id= — mark completed, unblock dependents
    api.post("/complete") { request, _ -> Response in
        let qp = request.uri.queryParameters
        guard let id = qp["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    UPDATE tasks
                    SET status = 'completed', completedAt = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [now, now, id]
                )
                // Unblock all tasks that were waiting on this one
                try unblockDependents(taskId: id, db: db)
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/task/fail?id= — mark failed
    api.post("/fail") { request, context -> Response in
        let qp = request.uri.queryParameters
        guard let id = qp["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let body = try? await request.decode(as: TaskFailRequest.self, context: context)
        let now = nowMs()

        do {
            try await dbPool.write { db in
                var sql = "UPDATE tasks SET status = 'failed', updatedAt = ?"
                var args: [any DatabaseValueConvertible] = [now]
                if let err = body?.lastError {
                    sql += ", lastError = ?"
                    args.append(err)
                }
                sql += " WHERE id = ?"
                args.append(id)
                try db.execute(sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/task/cancel?id= — mark cancelled
    api.post("/cancel") { request, _ -> Response in
        let qp = request.uri.queryParameters
        guard let id = qp["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE tasks SET status = 'cancelled', updatedAt = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/task/activate?id= — set active, startedAt=now
    api.post("/activate") { request, _ -> Response in
        let qp = request.uri.queryParameters
        guard let id = qp["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
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
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/task/retry?id= — increment retryCount, set pending
    api.post("/retry") { request, _ -> Response in
        let qp = request.uri.queryParameters
        guard let id = qp["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
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
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // GET /api/task/subtasks?parentId= — list by parentTask
    api.get("/subtasks") { request, _ -> Response in
        let qp = request.uri.queryParameters
        guard let parentId = qp["parentId"].map(String.init), !parentId.isEmpty else {
            return errorResponse("parentId parameter is required")
        }

        do {
            let rows = try await dbPool.read { db in
                try TaskRow.fetchAll(db, sql: """
                    SELECT * FROM tasks
                    WHERE parentTask = ?
                    ORDER BY createdAt ASC
                """, arguments: [parentId])
            }
            return jsonResponse(rows.map(rowToTaskResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // GET /api/task/stats — count by status
    api.get("/stats") { _, _ -> Response in
        do {
            let stats = try await dbPool.read { db -> TaskStatsResponse in
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
            return jsonResponse(stats)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
