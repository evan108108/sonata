import Foundation
import Hummingbird
import GRDB

// MARK: - Database Rows

struct CheckpointRow: FetchableRecord, Codable {
    static let databaseTableName = "checkpoints"
    var id: String
    var state: String
    var skills: String?
    var project: String?
    var createdAt: Int64
}

struct HandoffRow: FetchableRecord, Codable {
    static let databaseTableName = "handoffs"
    var id: String
    var content: String
    var createdAt: Int64
}

// MARK: - Request / Response

struct SaveCheckpointRequest: Decodable {
    let state: String
    let skills: String?
    let project: String?
}

struct CheckpointResponse: Encodable {
    let id: String
    let state: String
    let skills: String?
    let project: String?
    let createdAt: Int64
}

struct SaveHandoffRequest: Decodable {
    let content: String
}

struct HandoffResponse: Encodable {
    let id: String
    let content: String
    let createdAt: Int64
}

// MARK: - Schema Bootstrap

private func ensureCheckpointTables(_ db: Database) throws {
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS checkpoints (
            id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            skills TEXT,
            project TEXT,
            createdAt INTEGER NOT NULL
        )
    """)
    try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_checkpoints_createdAt
        ON checkpoints(createdAt DESC)
    """)
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS handoffs (
            id TEXT PRIMARY KEY,
            content TEXT NOT NULL,
            createdAt INTEGER NOT NULL
        )
    """)
    try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_handoffs_createdAt
        ON handoffs(createdAt DESC)
    """)
}

// MARK: - File System (backward compat)

private let activeCheckpointPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".sonata/scratch/active-checkpoint.md").path
}()

private func writeActiveCheckpointFile(state: String, skills: String?, project: String?, createdAt: Int64) {
    let dir = (activeCheckpointPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000.0))
    var lines = ["# Active Checkpoint", "", "**Saved:** \(ts)"]
    if let project { lines.append("**Project:** \(project)") }
    if let skills { lines.append("**Skills:** \(skills)") }
    lines.append("")
    lines.append("## State")
    lines.append("")
    lines.append(state)
    lines.append("")
    try? lines.joined(separator: "\n").write(toFile: activeCheckpointPath, atomically: true, encoding: .utf8)
}

private func clearActiveCheckpointFile() {
    try? FileManager.default.removeItem(atPath: activeCheckpointPath)
}

// MARK: - Route Registration

public func registerCheckpointRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    // Ensure tables exist once at registration time.
    Task.detached {
        try? await dbPool.write { db in
            try ensureCheckpointTables(db)
        }
    }

    // POST /api/checkpoint — save checkpoint
    router.post("/api/checkpoint") { request, context -> Response in
        guard let body = try? await request.decode(as: SaveCheckpointRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        let id = newUUID()
        let now = nowMs()

        do {
            try await dbPool.write { db in
                try ensureCheckpointTables(db)
                try db.execute(
                    sql: """
                    INSERT INTO checkpoints (id, state, skills, project, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [id, body.state, body.skills, body.project, now]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        writeActiveCheckpointFile(state: body.state, skills: body.skills, project: body.project, createdAt: now)

        return jsonResponse(CheckpointResponse(
            id: id,
            state: body.state,
            skills: body.skills,
            project: body.project,
            createdAt: now
        ), status: .created)
    }

    // GET /api/checkpoint — get latest checkpoint
    router.get("/api/checkpoint") { _, _ -> Response in
        do {
            let row = try await dbPool.read { db -> CheckpointRow? in
                try ensureCheckpointTables(db)
                return try CheckpointRow.fetchOne(
                    db,
                    sql: "SELECT * FROM checkpoints ORDER BY createdAt DESC LIMIT 1"
                )
            }
            guard let row else {
                return errorResponse("No active checkpoint", status: .notFound)
            }
            return jsonResponse(CheckpointResponse(
                id: row.id,
                state: row.state,
                skills: row.skills,
                project: row.project,
                createdAt: row.createdAt
            ))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // DELETE /api/checkpoint — clear active checkpoint
    router.delete("/api/checkpoint") { _, _ -> Response in
        do {
            try await dbPool.write { db in
                try ensureCheckpointTables(db)
                try db.execute(sql: "DELETE FROM checkpoints")
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
        clearActiveCheckpointFile()
        return jsonResponse(SuccessResponse())
    }

    // POST /api/handoff — save handoff letter
    router.post("/api/handoff") { request, context -> Response in
        guard let body = try? await request.decode(as: SaveHandoffRequest.self, context: context) else {
            return errorResponse("Invalid request body")
        }
        let id = newUUID()
        let now = nowMs()

        do {
            try await dbPool.write { db in
                try ensureCheckpointTables(db)
                try db.execute(
                    sql: "INSERT INTO handoffs (id, content, createdAt) VALUES (?, ?, ?)",
                    arguments: [id, body.content, now]
                )
            }
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }

        return jsonResponse(HandoffResponse(id: id, content: body.content, createdAt: now), status: .created)
    }

    // GET /api/handoff — get latest handoff
    router.get("/api/handoff") { _, _ -> Response in
        do {
            let row = try await dbPool.read { db -> HandoffRow? in
                try ensureCheckpointTables(db)
                return try HandoffRow.fetchOne(
                    db,
                    sql: "SELECT * FROM handoffs ORDER BY createdAt DESC LIMIT 1"
                )
            }
            guard let row else {
                return errorResponse("No handoff letter", status: .notFound)
            }
            return jsonResponse(HandoffResponse(id: row.id, content: row.content, createdAt: row.createdAt))
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
