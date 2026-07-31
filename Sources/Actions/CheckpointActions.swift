import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for /api/checkpoint + /api/handoff routes.
// Handler logic duplicated from CheckpointRoutes.swift.

// MARK: - Schema Bootstrap

// Internal rather than private so tests build their fixture from the real
// schema instead of a hand-copied CREATE TABLE that can drift away from it.
func ensureCheckpointTablesForAction(_ db: Database) throws {
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS checkpoints (
            id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            skills TEXT,
            project TEXT,
            createdAt INTEGER NOT NULL,
            sessionId TEXT
        )
    """)
    // The `sessionId` column may already exist on installs that ran the v31
    // migration — this ALTER handles installs that CREATE'd via this bootstrap
    // path before v31 ran.
    do { try db.execute(sql: "ALTER TABLE checkpoints ADD COLUMN sessionId TEXT") } catch { /* column exists */ }
    try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_checkpoints_createdAt
        ON checkpoints(createdAt DESC)
    """)
    try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_checkpoints_session_createdAt
        ON checkpoints(sessionId, createdAt DESC)
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

// MARK: - File System (session-scoped)
//
// Before session scoping, one shared `active-checkpoint.md` file served every
// session — the auto-inject hook read whichever session wrote last. Concurrent
// Claude Code sessions cross-contaminated: this session repeatedly received
// AE II / AE IV auto-captures as if they were its own. Now each session gets
// its own file. Callers without a sessionId still land on the legacy shared
// path so pre-migration harnesses keep working.

private let checkpointScratchDir: String = {
    URL(fileURLWithPath: SonataInstance.dataDirectory)
        .appendingPathComponent("scratch").path
}()

private let legacyActiveCheckpointPath: String = {
    (checkpointScratchDir as NSString).appendingPathComponent("active-checkpoint.md")
}()

/// Sanitize a sessionId for use in a filename. Session ids come from Claude
/// Code hooks (UUID-shaped) and MCP callers (their own key format) — both
/// should be filename-safe, but a stray slash from a mistyped key would
/// otherwise escape the scratch dir. Strip anything that isn't alnum/dash/
/// underscore/dot.
private func sanitizedSessionSlug(_ raw: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    let s = raw.unicodeScalars.filter { allowed.contains($0) }
    return String(String.UnicodeScalarView(s))
}

private func activeCheckpointPath(for sessionId: String?) -> String {
    guard let sessionId, !sessionId.isEmpty else { return legacyActiveCheckpointPath }
    let slug = sanitizedSessionSlug(sessionId)
    if slug.isEmpty { return legacyActiveCheckpointPath }
    return (checkpointScratchDir as NSString)
        .appendingPathComponent("active-checkpoint-\(slug).md")
}

private func writeActiveCheckpointFileForAction(
    state: String,
    skills: String?,
    project: String?,
    createdAt: Int64,
    sessionId: String?
) {
    let filePath = activeCheckpointPath(for: sessionId)
    try? FileManager.default.createDirectory(atPath: checkpointScratchDir, withIntermediateDirectories: true)
    let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000.0))
    var lines = ["# Active Checkpoint", "", "**Saved:** \(ts)"]
    if let sessionId, !sessionId.isEmpty { lines.append("**Session:** \(sessionId)") }
    if let project { lines.append("**Project:** \(project)") }
    if let skills { lines.append("**Skills:** \(skills)") }
    lines.append("")
    lines.append("## State")
    lines.append("")
    lines.append(state)
    lines.append("")
    try? lines.joined(separator: "\n").write(toFile: filePath, atomically: true, encoding: .utf8)
}

private func clearActiveCheckpointFileForAction(sessionId: String?) {
    // Clear the caller's session file if scoped; if unscoped, wipe both the
    // legacy shared file AND every per-session file so `checkpoint_delete`
    // still means "get rid of everything I can see."
    let scoped = activeCheckpointPath(for: sessionId)
    try? FileManager.default.removeItem(atPath: scoped)
    if sessionId == nil || sessionId?.isEmpty == true {
        try? FileManager.default.removeItem(atPath: legacyActiveCheckpointPath)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: checkpointScratchDir) {
            for name in entries where name.hasPrefix("active-checkpoint-") && name.hasSuffix(".md") {
                try? FileManager.default.removeItem(atPath: (checkpointScratchDir as NSString).appendingPathComponent(name))
            }
        }
    }
}

// MARK: - Lookup (EFB-48)
//
// Session scoping (v31) fixed *writes* but left restore with exactly one key:
// "newest row, maybe filtered by session." A session that dispatches three
// workers in the same minute saves three checkpoints — SQLite keeps all three,
// but only the newest is addressable, so two dispatches are silently
// unreachable. The clobber was never in storage; it was a missing read key.
//
// `byId` is that key. `mem_checkpoint_save` already returns the row id, so a
// dispatcher can hand each worker the exact checkpoint it should restore.
//
// Ordering is `createdAt DESC, rowid DESC` everywhere: createdAt is
// millisecond-resolution and a dispatch burst can produce ties, which would
// otherwise resolve arbitrarily.

/// Which checkpoint a restore call is asking for.
enum CheckpointLookup: Equatable {
    /// Exact checkpoint by its save-time id. Never falls back — a miss is a miss.
    case byId(String)
    /// Most recent checkpoint saved by one session.
    /// `allowLegacyFallback` opts into reading the pre-v31 NULL-sessionId
    /// bucket when the session owns no rows of its own.
    case bySession(String, allowLegacyFallback: Bool)
    /// Globally most recent row — the pre-scoping behavior.
    case latest
}

/// Decide what an incoming restore request is actually asking for.
///
/// Split out from the handler so the precedence rules are testable without a
/// live server: `checkpointId` wins over `sessionId` (an exact key should never
/// be weakened by a coarser one), and blank strings are treated as absent
/// because MCP callers routinely send `""` for an unset optional.
func resolveCheckpointLookup(
    checkpointId: String?,
    sessionId: String?,
    allowLegacyFallback: Bool
) -> CheckpointLookup {
    if let checkpointId, !checkpointId.isEmpty { return .byId(checkpointId) }
    if let sessionId, !sessionId.isEmpty {
        return .bySession(sessionId, allowLegacyFallback: allowLegacyFallback)
    }
    return .latest
}

/// Run a resolved lookup. Shared by the handler and its tests so the two can't
/// drift apart on ordering or fallback semantics.
func fetchCheckpoint(_ db: Database, _ lookup: CheckpointLookup) throws -> CheckpointRow? {
    switch lookup {
    case .byId(let id):
        return try CheckpointRow.fetchOne(
            db,
            sql: "SELECT * FROM checkpoints WHERE id = ?",
            arguments: [id]
        )

    case .bySession(let sessionId, let allowLegacyFallback):
        if let scoped = try CheckpointRow.fetchOne(
            db,
            sql: "SELECT * FROM checkpoints WHERE sessionId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 1",
            arguments: [sessionId]
        ) {
            return scoped
        }
        guard allowLegacyFallback else { return nil }
        return try CheckpointRow.fetchOne(
            db,
            sql: "SELECT * FROM checkpoints WHERE sessionId IS NULL ORDER BY createdAt DESC, rowid DESC LIMIT 1"
        )

    case .latest:
        return try CheckpointRow.fetchOne(
            db,
            sql: "SELECT * FROM checkpoints ORDER BY createdAt DESC, rowid DESC LIMIT 1"
        )
    }
}

// MARK: - Actions

let checkpointActions: [SonataAction] = [

    // POST /api/checkpoint — save checkpoint
    SonataAction(
        name: "mem_checkpoint_save",
        description: "Save a session checkpoint (state, skills, project) and write active-checkpoint-<sessionId>.md. Pass sessionId to scope the checkpoint to your session — without it, the checkpoint lands in the legacy shared bucket and can be overwritten by any other session.",
        group: "/api",
        path: "/checkpoint",
        method: .post,
        params: [
            ActionParam("state", .string, required: true, description: "Checkpoint state / working notes"),
            ActionParam("skills", .string, description: "Active skills"),
            ActionParam("project", .string, description: "Project namespace"),
            ActionParam("sessionId", .string, description: "Caller's session id — scopes save and restore to prevent cross-session contamination. Optional for backwards compat; strongly recommended."),
        ],
        handler: { ctx in
            let state = try ctx.params.require("state")
            let skills = ctx.params.string("skills")
            let project = ctx.params.string("project")
            let sessionId = ctx.params.string("sessionId")

            let id = newUUID()
            let now = nowMs()

            do {
                try await ctx.dbPool.write { db in
                    try ensureCheckpointTablesForAction(db)
                    try db.execute(
                        sql: """
                        INSERT INTO checkpoints (id, state, skills, project, createdAt, sessionId)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [id, state, skills, project, now, sessionId]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }

            writeActiveCheckpointFileForAction(
                state: state,
                skills: skills,
                project: project,
                createdAt: now,
                sessionId: sessionId
            )

            return CheckpointResponse(
                id: id,
                state: state,
                skills: skills,
                project: project,
                createdAt: now,
                sessionId: sessionId
            )
        }
    ),

    // GET /api/checkpoint — get latest checkpoint
    SonataAction(
        name: "mem_checkpoint_restore",
        description: "Return a checkpoint. Pass checkpointId for an exact one (the id mem_checkpoint_save returned) — that is the only lookup immune to parallel dispatches from one session. Otherwise pass sessionId for the most recent that session saved. With neither, you get the globally-most-recent row and risk restoring another session's state.",
        group: "/api",
        path: "/checkpoint",
        method: .get,
        params: [
            ActionParam("checkpointId", .string, description: "Exact checkpoint id, as returned by mem_checkpoint_save. Takes precedence over sessionId and never falls back — if it does not exist you get not-found, not someone else's state. Use this when a dispatcher hands you a specific checkpoint."),
            ActionParam("sessionId", .string, description: "Caller's session id. Returns the most-recent checkpoint saved by that session. If the session has none, this is not-found — it will NOT silently hand back a legacy or foreign checkpoint unless you also pass allowLegacyFallback."),
            ActionParam("allowLegacyFallback", .boolean, description: "Opt in to reading the pre-scoping NULL-sessionId bucket when sessionId matches no rows. Default false. Only set this if you specifically want pre-v31 checkpoints; it can return a checkpoint that is not yours."),
        ],
        handler: { ctx in
            let checkpointId = ctx.params.string("checkpointId")
            let sessionId = ctx.params.string("sessionId")
            let allowLegacyFallback = ctx.params.bool("allowLegacyFallback") ?? false
            let lookup = resolveCheckpointLookup(
                checkpointId: checkpointId,
                sessionId: sessionId,
                allowLegacyFallback: allowLegacyFallback
            )
            do {
                let row = try await ctx.dbPool.read { db -> CheckpointRow? in
                    try ensureCheckpointTablesForAction(db)
                    return try fetchCheckpoint(db, lookup)
                }
                guard let row else {
                    // Say which key missed. "No active checkpoint" sent callers
                    // hunting for a save bug when the real answer was usually
                    // "you asked with the wrong key."
                    switch lookup {
                    case .byId(let id):
                        throw ActionError.notFound("No checkpoint with id \(id)")
                    case .bySession(let sid, _):
                        throw ActionError.notFound("No checkpoint saved by session \(sid)")
                    case .latest:
                        throw ActionError.notFound("No active checkpoint")
                    }
                }
                return CheckpointResponse(
                    id: row.id,
                    state: row.state,
                    skills: row.skills,
                    project: row.project,
                    createdAt: row.createdAt,
                    sessionId: row.sessionId
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
        description: "Clear checkpoints and remove active-checkpoint file(s). Pass sessionId to delete ONLY that session's rows and file — omit to wipe everything (pre-scoping behavior).",
        group: "/api",
        path: "/checkpoint",
        method: .delete,
        params: [
            ActionParam("sessionId", .string, description: "Caller's session id. When set, deletes only that session's checkpoints (and its active-checkpoint-<sessionId>.md file). When omitted, wipes ALL checkpoints and every per-session file — the global reset."),
        ],
        handler: { ctx in
            let sessionId = ctx.params.string("sessionId")
            do {
                try await ctx.dbPool.write { db in
                    try ensureCheckpointTablesForAction(db)
                    if let sessionId, !sessionId.isEmpty {
                        try db.execute(
                            sql: "DELETE FROM checkpoints WHERE sessionId = ?",
                            arguments: [sessionId]
                        )
                    } else {
                        try db.execute(sql: "DELETE FROM checkpoints")
                    }
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            clearActiveCheckpointFileForAction(sessionId: sessionId)
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
