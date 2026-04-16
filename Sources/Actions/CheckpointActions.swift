import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/checkpoint + /api/handoff routes.
// Handler logic duplicated from CheckpointRoutes.swift.

// MARK: - Schema Bootstrap

private func ensureCheckpointTablesForAction(_ db: Database) throws {
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

private let activeCheckpointPathForAction: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".sonata/scratch/active-checkpoint.md").path
}()

private func writeActiveCheckpointFileForAction(state: String, skills: String?, project: String?, createdAt: Int64) {
    let dir = (activeCheckpointPathForAction as NSString).deletingLastPathComponent
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
    try? lines.joined(separator: "\n").write(toFile: activeCheckpointPathForAction, atomically: true, encoding: .utf8)
}

private func clearActiveCheckpointFileForAction() {
    try? FileManager.default.removeItem(atPath: activeCheckpointPathForAction)
}

// MARK: - Actions

let checkpointActions: [SonataAction] = [

    // POST /api/checkpoint — save checkpoint
    SonataAction(
        name: "mem_checkpoint_save",
        description: "Save a session checkpoint (state, skills, project) and write active-checkpoint.md.",
        group: "/api",
        path: "/checkpoint",
        method: .post,
        params: [
            ActionParam("state", .string, required: true, description: "Checkpoint state / working notes"),
            ActionParam("skills", .string, description: "Active skills"),
            ActionParam("project", .string, description: "Project namespace"),
        ],
        handler: { ctx in
            let state = try ctx.params.require("state")
            let skills = ctx.params.string("skills")
            let project = ctx.params.string("project")

            let id = newUUID()
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    try ensureCheckpointTablesForAction(db)
                    try db.execute(
                        sql: """
                        INSERT INTO checkpoints (id, state, skills, project, createdAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [id, state, skills, project, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            writeActiveCheckpointFileForAction(state: state, skills: skills, project: project, createdAt: now)

            return CheckpointResponse(
                id: id,
                state: state,
                skills: skills,
                project: project,
                createdAt: now
            )
        }
    ),

    // GET /api/checkpoint — get latest checkpoint
    SonataAction(
        name: "mem_checkpoint_restore",
        description: "Return the most recent checkpoint, or not-found if none exists.",
        group: "/api",
        path: "/checkpoint",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let row = try await ctx.dbPool.read { db -> CheckpointRow? in
                    try ensureCheckpointTablesForAction(db)
                    return try CheckpointRow.fetchOne(
                        db,
                        sql: "SELECT * FROM checkpoints ORDER BY createdAt DESC LIMIT 1"
                    )
                }
                guard let row else {
                    throw ActionError.notFound("No active checkpoint")
                }
                return CheckpointResponse(
                    id: row.id,
                    state: row.state,
                    skills: row.skills,
                    project: row.project,
                    createdAt: row.createdAt
                )
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // DELETE /api/checkpoint — clear active checkpoint
    SonataAction(
        name: "checkpoint_delete",
        description: "Clear all checkpoints and remove the active-checkpoint.md file.",
        group: "/api",
        path: "/checkpoint",
        method: .delete,
        params: [],
        handler: { ctx in
            do {
                try await ctx.dbPool.write { db in
                    try ensureCheckpointTablesForAction(db)
                    try db.execute(sql: "DELETE FROM checkpoints")
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            clearActiveCheckpointFileForAction()
            return SuccessResponse()
        }
    ),

    // POST /api/handoff — save handoff letter
    SonataAction(
        name: "mem_handoff",
        description: "Save a handoff letter for the next session.",
        group: "/api",
        path: "/handoff",
        method: .post,
        params: [
            ActionParam("content", .string, required: true, description: "Handoff letter content"),
        ],
        handler: { ctx in
            let content = try ctx.params.require("content")
            let id = newUUID()
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    try ensureCheckpointTablesForAction(db)
                    try db.execute(
                        sql: "INSERT INTO handoffs (id, content, createdAt) VALUES (?, ?, ?)",
                        arguments: [id, content, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            return HandoffResponse(id: id, content: content, createdAt: now)
        }
    ),

    // GET /api/handoff — get latest handoff
    SonataAction(
        name: "handoff_get",
        description: "Return the most recent handoff letter, or not-found if none exists.",
        group: "/api",
        path: "/handoff",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                let row = try await ctx.dbPool.read { db -> HandoffRow? in
                    try ensureCheckpointTablesForAction(db)
                    return try HandoffRow.fetchOne(
                        db,
                        sql: "SELECT * FROM handoffs ORDER BY createdAt DESC LIMIT 1"
                    )
                }
                guard let row else {
                    throw ActionError.notFound("No handoff letter")
                }
                return HandoffResponse(id: row.id, content: row.content, createdAt: row.createdAt)
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),
]
