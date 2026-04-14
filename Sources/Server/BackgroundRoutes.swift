import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct BackgroundJobRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "backgroundJobs"

    var id: String
    var name: String
    var status: String
    var prompt: String
    var model: String?
    var maxTurns: Int?
    var result: String?
    var error: String?
    var createdAt: Int64
    var startedAt: Int64?
    var completedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, status, prompt, model, maxTurns
        case result, error, createdAt, startedAt, completedAt
    }
}

// MARK: - Request Bodies

struct CreateBackgroundJobRequest: Decodable {
    let name: String
    let prompt: String
    let model: String?
    let maxTurns: Int?
}

struct CompleteJobRequest: Decodable {
    let result: String?
}

struct FailJobRequest: Decodable {
    let error: String?
}

// MARK: - Response Types

struct BackgroundJobResponse: Encodable {
    let _id: String
    let name: String
    let status: String
    let prompt: String
    let model: String?
    let maxTurns: Int?
    let result: String?
    let error: String?
    let createdAt: Int64
    let startedAt: Int64?
    let completedAt: Int64?
}

struct TimeoutResponse: Encodable {
    let timedOut: Int
    let success = true
}

struct CleanupResponse: Encodable {
    let deleted: Int
    let success = true
}

// MARK: - Helpers

private func jobToResponse(_ row: BackgroundJobRow) -> BackgroundJobResponse {
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

/// Create a background job with the given name and prompt.
private func createJob(
    name: String,
    prompt: String,
    dbPool: DatabasePool
) async -> Response {
    let now = nowMs()
    let id = newUUID()

    do {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO backgroundJobs (id, name, status, prompt, createdAt)
                VALUES (?, ?, 'pending', ?, ?)
                """,
                arguments: [id, name, prompt, now]
            )
        }
    } catch {
        return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
    }

    return jsonResponse(StoreResponse(id: id), status: .created)
}

// MARK: - Route Registration

public func registerBackgroundRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    let api = router.group("/api/background-jobs")

    // GET /api/background-jobs?status=&limit= — list jobs
    api.get("/") { request, _ -> Response in
        let queryParams = request.uri.queryParameters
        let limit = Int(queryParams["limit"] ?? "") ?? 50
        let status = queryParams["status"].map(String.init)

        var sql = "SELECT * FROM backgroundJobs WHERE 1=1"
        var args: [any DatabaseValueConvertible] = []

        if let s = status {
            sql += " AND status = ?"
            args.append(s)
        }
        sql += " ORDER BY createdAt DESC LIMIT ?"
        args.append(limit)

        do {
            let rows = try await dbPool.read { db in
                try BackgroundJobRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            return jsonResponse(rows.map(jobToResponse))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/background-jobs — create job
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: CreateBackgroundJobRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        guard !body.name.isEmpty, !body.prompt.isEmpty else {
            return errorResponse("name and prompt are required")
        }

        let now = nowMs()
        let id = newUUID()

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO backgroundJobs (id, name, status, prompt, model, maxTurns, createdAt)
                    VALUES (?, ?, 'pending', ?, ?, ?, ?)
                    """,
                    arguments: [id, body.name, body.prompt, body.model, body.maxTurns, now]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(StoreResponse(id: id), status: .created)
    }

    // POST /api/background-jobs/claim?id= — set running, startedAt
    api.post("/claim") { request, _ -> Response in
        guard let id = request.uri.queryParameters["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let now = nowMs()
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE backgroundJobs SET status = 'running', startedAt = ? WHERE id = ? AND status = 'pending'",
                    arguments: [now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/background-jobs/complete?id= — set completed, result
    api.post("/complete") { request, context -> Response in
        guard let id = request.uri.queryParameters["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let body = try? await request.decode(as: CompleteJobRequest.self, context: context)
        let now = nowMs()

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE backgroundJobs SET status = 'completed', result = ?, completedAt = ? WHERE id = ?",
                    arguments: [body?.result, now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/background-jobs/fail?id= — set failed, error
    api.post("/fail") { request, context -> Response in
        guard let id = request.uri.queryParameters["id"].map(String.init), !id.isEmpty else {
            return errorResponse("id parameter is required")
        }

        let body = try? await request.decode(as: FailJobRequest.self, context: context)
        let now = nowMs()

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE backgroundJobs SET status = 'failed', error = ?, completedAt = ? WHERE id = ?",
                    arguments: [body?.error, now, id]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(SuccessResponse())
    }

    // POST /api/background-jobs/timeout-stale — timeout running jobs older than 15min
    api.post("/timeout-stale") { _, _ -> Response in
        let cutoff = nowMs() - 15 * 60 * 1000  // 15 minutes
        let now = nowMs()

        do {
            let count = try await dbPool.write { db -> Int in
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
            return jsonResponse(TimeoutResponse(timedOut: count))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/background-jobs/cleanup?retentionDays= — delete old completed/failed jobs
    api.post("/cleanup") { request, _ -> Response in
        let retentionDays = Int(request.uri.queryParameters["retentionDays"] ?? "") ?? 7
        let cutoff = nowMs() - Int64(retentionDays) * 86400 * 1000

        do {
            let count = try await dbPool.write { db -> Int in
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
            return jsonResponse(CleanupResponse(deleted: count))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // MARK: Manual trigger routes under /api/background/*

    let bg = router.group("/api/background")

    bg.post("/consolidate") { _, _ -> Response in
        await createJob(name: "consolidate", prompt: "Run memory consolidation: find duplicate/overlapping memories and merge them.", dbPool: dbPool)
    }
    bg.post("/enrich") { _, _ -> Response in
        await createJob(name: "enrich", prompt: "Run memory enrichment: add LOD tiers (l0, l1) to memories missing them.", dbPool: dbPool)
    }
    bg.post("/reflect") { _, _ -> Response in
        await createJob(name: "reflect", prompt: "Run reflection: review recent memories and generate insights.", dbPool: dbPool)
    }
    bg.post("/think") { _, _ -> Response in
        await createJob(name: "think", prompt: "Run deep thinking: contemplate patterns across memories and generate new connections.", dbPool: dbPool)
    }
    bg.post("/hygiene") { _, _ -> Response in
        await createJob(name: "hygiene", prompt: "Run hygiene: archive stale memories, fix broken relations, clean up orphans.", dbPool: dbPool)
    }
    bg.post("/compress") { _, _ -> Response in
        await createJob(name: "compress", prompt: "Run compression: compress verbose memories into more concise forms.", dbPool: dbPool)
    }
    bg.post("/collision") { _, _ -> Response in
        await createJob(name: "collision", prompt: "Run collision detection: find contradictory memories and resolve conflicts.", dbPool: dbPool)
    }
    bg.post("/dialogue") { _, _ -> Response in
        await createJob(name: "dialogue", prompt: "Run inner dialogue: engage in self-reflective conversation about recent experiences.", dbPool: dbPool)
    }
    bg.post("/curiosity") { _, _ -> Response in
        await createJob(name: "curiosity", prompt: "Run curiosity: identify knowledge gaps and generate questions to explore.", dbPool: dbPool)
    }
    bg.post("/personality") { _, _ -> Response in
        await createJob(name: "personality", prompt: "Run personality update: review recent interactions and update personality map.", dbPool: dbPool)
    }
    bg.post("/world-watch") { _, _ -> Response in
        await createJob(name: "world-watch", prompt: "Run world watch: scan for interesting developments in tracked topics.", dbPool: dbPool)
    }
    bg.post("/wiki-compile") { _, _ -> Response in
        await createJob(name: "wiki-compile", prompt: "Run wiki compilation: recompile dirty wiki pages from current memories.", dbPool: dbPool)
    }
    bg.post("/analyze-signals") { _, _ -> Response in
        await createJob(name: "analyze-signals", prompt: "Run signal analysis: analyze recent observations for actionable patterns.", dbPool: dbPool)
    }
}
