import Foundation
import GRDB
import Hummingbird

// MARK: - Watchers (filesystem event source primitive)
//
// Actions for /api/watcher — CRUD, enable/disable, test-fire, recent-events.
// The FSEventStream lifecycle lives in `WatcherRunner` (Sources/Scheduler/);
// this file only reads and writes rows, then posts a reload notification the
// runner listens for. Keeping the action layer free of the C-callback details
// mirrors how SchedulerActions relates to SchedulerActor.
//
// Naming: this is NOT `TaskWatcherActions` (that's the task-status
// subscription feature — mem_task_watch/unwatch). Filesystem watchers use the
// bare `watcher_*` prefix throughout.

/// Broadcast when any watcher row is created, updated, or deleted. The
/// WatcherRunner listens and re-registers FSEventStreams to match.
extension Notification.Name {
    static let sonataWatchersChanged = Notification.Name("SonataWatchersChanged")
}

private let validWatcherTriggers: Set<String> = [
    "file_added", "file_modified", "file_deleted", "size_threshold"
]

private let watcherSlugPattern = "^[A-Za-z0-9_-]{1,64}$"

private func validateSlug(_ id: String) throws {
    guard let re = try? NSRegularExpression(pattern: watcherSlugPattern),
          re.firstMatch(
              in: id,
              range: NSRange(id.startIndex..., in: id)
          ) != nil
    else {
        throw ActionError.invalidParam("id", "must match \(watcherSlugPattern)")
    }
}

private func postWatchersChanged() {
    NotificationCenter.default.post(name: .sonataWatchersChanged, object: nil)
}

// MARK: - Row + response shape

struct WatcherRow: FetchableRecord, Decodable, Sendable {
    let id: String
    let name: String
    let path: String
    let pattern: String
    let recursive: Int
    let trigger: String
    let prompt: String
    let enabled: Int
    let cooldownMs: Int64
    let retryCount: Int
    let sizeThreshold: Int64?
    let lastError: String?
    let consecutiveFailures: Int
    let lastFiredAt: Int64?
    let createdAt: Int64
    let updatedAt: Int64
}

struct WatcherResponse: Encodable {
    let id: String
    let name: String
    let path: String
    let pattern: String
    let recursive: Bool
    let trigger: String
    let prompt: String
    let enabled: Bool
    let cooldownMs: Int64
    let retryCount: Int
    let sizeThreshold: Int64?
    let lastError: String?
    let consecutiveFailures: Int
    let lastFiredAt: Int64?
    let createdAt: Int64
    let updatedAt: Int64
}

private func rowToResp(_ row: WatcherRow) -> WatcherResponse {
    WatcherResponse(
        id: row.id,
        name: row.name,
        path: row.path,
        pattern: row.pattern,
        recursive: row.recursive != 0,
        trigger: row.trigger,
        prompt: row.prompt,
        enabled: row.enabled != 0,
        cooldownMs: row.cooldownMs,
        retryCount: row.retryCount,
        sizeThreshold: row.sizeThreshold,
        lastError: row.lastError,
        consecutiveFailures: row.consecutiveFailures,
        lastFiredAt: row.lastFiredAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

struct WatcherEventRow: FetchableRecord, Decodable, Sendable {
    let id: String
    let watcherId: String
    let path: String
    let eventType: String
    let firedAt: Int64
    let taskId: String?
    let status: String
    let error: String?
}

struct WatcherEventResponse: Encodable {
    let id: String
    let watcherId: String
    let path: String
    let eventType: String
    let firedAt: Int64
    let taskId: String?
    let status: String
    let error: String?
}

private func eventRowToResp(_ row: WatcherEventRow) -> WatcherEventResponse {
    WatcherEventResponse(
        id: row.id,
        watcherId: row.watcherId,
        path: row.path,
        eventType: row.eventType,
        firedAt: row.firedAt,
        taskId: row.taskId,
        status: row.status,
        error: row.error
    )
}

struct WatcherTestResponse: Encodable {
    let ok: Bool
    let taskId: String?
    let status: String
    let error: String?
}

// MARK: - Factory

/// Actions are constructed via a factory (not a top-level `let`) so
/// `watcher_test` can capture the live `WatcherRunner` at boot without threading
/// a global. Mirrors `makeWebhookActions(registry:)`.
func makeWatcherActions(runner: WatcherRunner?) -> [SonataAction] {
    [
        // GET /api/watcher/list
        SonataAction(
            name: "watcher_list",
            description: "List all filesystem watchers (both enabled and disabled).",
            group: "/api/watcher",
            path: "/list",
            method: .get,
            params: [],
            handler: { ctx in
                do {
                    let rows = try await ctx.dbPool.read { db in
                        try WatcherRow.fetchAll(db, sql: "SELECT * FROM watchers ORDER BY name ASC")
                    }
                    return rows.map(rowToResp)
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
            }
        ),

        // GET /api/watcher/get?id=
        SonataAction(
            name: "watcher_get",
            description: "Get a single watcher by id.",
            group: "/api/watcher",
            path: "/get",
            method: .get,
            params: [
                ActionParam("id", .string, required: true, description: "Watcher id"),
            ],
            handler: { ctx in
                let id = try ctx.params.require("id")
                do {
                    let row = try await ctx.dbPool.read { db in
                        try WatcherRow.fetchOne(
                            db,
                            sql: "SELECT * FROM watchers WHERE id = ?",
                            arguments: [id]
                        )
                    }
                    guard let row else { throw ActionError.notFound("Watcher not found: \(id)") }
                    return rowToResp(row)
                } catch let e as ActionError {
                    throw e
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
            }
        ),

        // POST /api/watcher/create — upsert by id (id defaults to slugified name)
        SonataAction(
            name: "watcher_create",
            description: """
                Create or replace a filesystem watcher. id is a stable slug (\
                A-Za-z0-9_-, ≤64). Trigger: file_added | file_modified | \
                file_deleted | size_threshold. Prompt is either a slash-command \
                (/meeting) or a free-form prompt; tokens {{path}} {{name}} \
                {{ext}} {{dir}} {{event}} {{watcher}} are substituted at fire \
                time — if none are present, a preamble with the file path is \
                prepended.
                """,
            group: "/api/watcher",
            path: "/create",
            method: .post,
            params: [
                ActionParam("id", .string, description: "Stable id (slug). If omitted, derived from name."),
                ActionParam("name", .string, required: true, description: "Human name"),
                ActionParam("path", .string, required: true, description: "Absolute path to watch"),
                ActionParam("pattern", .string, description: "Glob pattern (default '*')"),
                ActionParam("recursive", .boolean, description: "Recurse into subdirs (default false)"),
                ActionParam("trigger", .string, description: "Trigger type (default file_added)"),
                ActionParam("prompt", .string, required: true, description: "Slash command or free-form prompt"),
                ActionParam("enabled", .boolean, description: "Enabled (default true)"),
                ActionParam("cooldownMs", .integer, description: "Debounce window in ms (default 5000)"),
                ActionParam("retryCount", .integer, description: "Retries on failure (default 2)"),
                ActionParam("sizeThreshold", .integer, description: "Byte threshold for size_threshold trigger"),
            ],
            handler: { ctx in
                let name = try ctx.params.require("name")
                let path = try ctx.params.require("path")
                let prompt = try ctx.params.require("prompt")
                let idInput = ctx.params.string("id")
                let id = try {
                    if let v = idInput, !v.isEmpty {
                        try validateSlug(v)
                        return v
                    }
                    // Slugify the name — lowercase, keep [A-Za-z0-9_-], collapse others to '-'
                    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
                    let derived = String(name.lowercased().map { allowed.contains($0) ? $0 : "-" })
                        .split(separator: "-", omittingEmptySubsequences: true)
                        .joined(separator: "-")
                    guard !derived.isEmpty else {
                        throw ActionError.invalidParam("name", "produces empty slug — set id explicitly")
                    }
                    return String(derived.prefix(64))
                }()

                let pattern = ctx.params.string("pattern") ?? "*"
                let recursive = (ctx.params.bool("recursive") ?? false) ? 1 : 0
                let trigger = ctx.params.string("trigger") ?? "file_added"
                guard validWatcherTriggers.contains(trigger) else {
                    let allowed = validWatcherTriggers.sorted().joined(separator: ", ")
                    throw ActionError.invalidParam("trigger", "must be one of \(allowed)")
                }
                let enabled = (ctx.params.bool("enabled") ?? true) ? 1 : 0
                let cooldownMs = Int64(ctx.params.int("cooldownMs") ?? 5000)
                let retryCount = ctx.params.int("retryCount") ?? 2
                let sizeThreshold: Int64? = ctx.params.int("sizeThreshold").map { Int64($0) }

                let now = nowMs()
                do {
                    try await ctx.dbPool.write { db in
                        try db.execute(
                            sql: """
                            INSERT INTO watchers
                                (id, name, path, pattern, recursive, trigger, prompt,
                                 enabled, cooldownMs, retryCount, sizeThreshold,
                                 lastError, consecutiveFailures, lastFiredAt,
                                 createdAt, updatedAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, NULL, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                                name = excluded.name,
                                path = excluded.path,
                                pattern = excluded.pattern,
                                recursive = excluded.recursive,
                                trigger = excluded.trigger,
                                prompt = excluded.prompt,
                                enabled = excluded.enabled,
                                cooldownMs = excluded.cooldownMs,
                                retryCount = excluded.retryCount,
                                sizeThreshold = excluded.sizeThreshold,
                                updatedAt = excluded.updatedAt
                            """,
                            arguments: [
                                id, name, path, pattern, recursive, trigger, prompt,
                                enabled, cooldownMs, retryCount, sizeThreshold,
                                now, now,
                            ]
                        )
                    }
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
                postWatchersChanged()
                return WatcherResponse(
                    id: id, name: name, path: path, pattern: pattern,
                    recursive: recursive != 0, trigger: trigger, prompt: prompt,
                    enabled: enabled != 0, cooldownMs: cooldownMs,
                    retryCount: retryCount, sizeThreshold: sizeThreshold,
                    lastError: nil, consecutiveFailures: 0, lastFiredAt: nil,
                    createdAt: now, updatedAt: now
                )
            }
        ),

        // PATCH /api/watcher/update — partial update
        SonataAction(
            name: "watcher_update",
            description: "Update a watcher's fields. Only provided fields are changed.",
            group: "/api/watcher",
            path: "/update",
            method: .patch,
            params: [
                ActionParam("id", .string, required: true, description: "Watcher id"),
                ActionParam("name", .string, description: "New name"),
                ActionParam("path", .string, description: "New watched path"),
                ActionParam("pattern", .string, description: "New glob pattern"),
                ActionParam("recursive", .boolean, description: "Recurse into subdirs"),
                ActionParam("trigger", .string, description: "New trigger type"),
                ActionParam("prompt", .string, description: "New prompt"),
                ActionParam("cooldownMs", .integer, description: "New debounce window"),
                ActionParam("retryCount", .integer, description: "New retry count"),
                ActionParam("sizeThreshold", .integer, description: "New size threshold"),
            ],
            handler: { ctx in
                let id = try ctx.params.require("id")

                var sets: [String] = []
                var args: [any DatabaseValueConvertible] = []
                if let v = ctx.params.string("name") { sets.append("name = ?"); args.append(v) }
                if let v = ctx.params.string("path") { sets.append("path = ?"); args.append(v) }
                if let v = ctx.params.string("pattern") { sets.append("pattern = ?"); args.append(v) }
                if let v = ctx.params.bool("recursive") { sets.append("recursive = ?"); args.append(v ? 1 : 0) }
                if let v = ctx.params.string("trigger") {
                    guard validWatcherTriggers.contains(v) else {
                        let allowed = validWatcherTriggers.sorted().joined(separator: ", ")
                        throw ActionError.invalidParam("trigger", "must be one of \(allowed)")
                    }
                    sets.append("trigger = ?"); args.append(v)
                }
                if let v = ctx.params.string("prompt") { sets.append("prompt = ?"); args.append(v) }
                if let v = ctx.params.int("cooldownMs") { sets.append("cooldownMs = ?"); args.append(Int64(v)) }
                if let v = ctx.params.int("retryCount") { sets.append("retryCount = ?"); args.append(v) }
                if let v = ctx.params.int("sizeThreshold") { sets.append("sizeThreshold = ?"); args.append(Int64(v)) }

                guard !sets.isEmpty else {
                    throw ActionError.invalidParam("<body>", "no fields to update")
                }
                sets.append("updatedAt = ?")
                args.append(nowMs())
                args.append(id)

                let setClause = sets.joined(separator: ", ")
                do {
                    try await ctx.dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE watchers SET \(setClause) WHERE id = ?",
                            arguments: StatementArguments(args)
                        )
                    }
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
                postWatchersChanged()
                return SuccessResponse()
            }
        ),

        // DELETE /api/watcher/delete?id=
        SonataAction(
            name: "watcher_delete",
            description: "Delete a watcher. Its event history is preserved.",
            group: "/api/watcher",
            path: "/delete",
            method: .delete,
            params: [
                ActionParam("id", .string, required: true, description: "Watcher id"),
            ],
            handler: { ctx in
                let id = try ctx.params.require("id")
                do {
                    try await ctx.dbPool.write { db in
                        try db.execute(sql: "DELETE FROM watchers WHERE id = ?", arguments: [id])
                    }
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
                postWatchersChanged()
                return SuccessResponse()
            }
        ),

        // POST /api/watcher/enable
        SonataAction(
            name: "watcher_enable",
            description: "Enable a watcher and clear its failure counter.",
            group: "/api/watcher",
            path: "/enable",
            method: .post,
            params: [
                ActionParam("id", .string, required: true, description: "Watcher id"),
            ],
            handler: { ctx in
                let id = try ctx.params.require("id")
                let now = nowMs()
                do {
                    try await ctx.dbPool.write { db in
                        try db.execute(
                            sql: """
                            UPDATE watchers
                            SET enabled = 1, consecutiveFailures = 0, lastError = NULL, updatedAt = ?
                            WHERE id = ?
                            """,
                            arguments: [now, id]
                        )
                    }
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
                postWatchersChanged()
                return SuccessResponse()
            }
        ),

        // POST /api/watcher/disable
        SonataAction(
            name: "watcher_disable",
            description: "Disable a watcher. Its FSEventStream is torn down until re-enabled.",
            group: "/api/watcher",
            path: "/disable",
            method: .post,
            params: [
                ActionParam("id", .string, required: true, description: "Watcher id"),
            ],
            handler: { ctx in
                let id = try ctx.params.require("id")
                let now = nowMs()
                do {
                    try await ctx.dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE watchers SET enabled = 0, updatedAt = ? WHERE id = ?",
                            arguments: [now, id]
                        )
                    }
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
                postWatchersChanged()
                return SuccessResponse()
            }
        ),

        // POST /api/watcher/test — synthetic fire against an existing file
        SonataAction(
            name: "watcher_test",
            description: "Fire a watcher's dispatch path manually against an existing file, without waiting for a real FSEvent. Returns the dispatched task id (or the error).",
            group: "/api/watcher",
            path: "/test",
            method: .post,
            params: [
                ActionParam("id", .string, required: true, description: "Watcher id"),
                ActionParam("path", .string, required: true, description: "Absolute path to fire against"),
            ],
            handler: { ctx in
                let id = try ctx.params.require("id")
                let path = try ctx.params.require("path")
                guard let runner else {
                    throw ActionError.custom("Watcher runner not available", .internalServerError)
                }
                let result = await runner.testFire(watcherId: id, path: path)
                return WatcherTestResponse(
                    ok: result.taskId != nil,
                    taskId: result.taskId,
                    status: result.status,
                    error: result.error
                )
            }
        ),

        // GET /api/watcher/events?id=&limit=
        SonataAction(
            name: "watcher_events_recent",
            description: "Recent events for a watcher (most recent first).",
            group: "/api/watcher",
            path: "/events",
            method: .get,
            params: [
                ActionParam("id", .string, required: true, description: "Watcher id"),
                ActionParam("limit", .integer, description: "Max rows (default 50, cap 500)"),
            ],
            handler: { ctx in
                let id = try ctx.params.require("id")
                let limit = min(max(ctx.params.int("limit") ?? 50, 1), 500)
                do {
                    let rows = try await ctx.dbPool.read { db in
                        try WatcherEventRow.fetchAll(
                            db,
                            sql: """
                            SELECT * FROM watcher_events
                            WHERE watcherId = ?
                            ORDER BY firedAt DESC
                            LIMIT ?
                            """,
                            arguments: [id, limit]
                        )
                    }
                    return rows.map(eventRowToResp)
                } catch {
                    throw ActionError.database(error.localizedDescription)
                }
            }
        ),
    ]
}
