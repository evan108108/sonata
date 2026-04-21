import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: composite MCP-only tools that fan out multiple DB queries.
// These have mcpOnly: true — no HTTP route is registered. The `group` and `path`
// fields are set to nominal values (e.g. /api + /wake) but are never used for routing.
//
// Deviations from planning doc (sonata-action-abstraction.md:1936-2333):
//  - Planning doc used trailing-closure init syntax; we use the real `handler:` param.
//  - Planning doc referenced a `payload` column on backgroundJobs — schema actually
//    uses `prompt`. All JSON payloads here go into the `prompt` column.
//  - Planning doc referenced `parentId` on tasks — schema column is `parentTask`.
//  - Planning doc referenced undefined formatter symbols (formatWakeBriefing etc.);
//    those are omitted — results fall back to JSON.
//  - wikiPages has no `status` column; mem_coverage uses `pageType` surfaced as
//    `status` to match the spirit of the planning doc.
//  - mem_visualize is a deferred-execution stub: it enqueues a backgroundJob
//    instead of calling OpenAI directly.

// MARK: - Inline response structs

private struct HandoffRecord: Encodable {
    let id: String
    let content: String
    let createdAt: Int64
}

private struct MemorySummary: Encodable {
    let _id: String
    let content: String
    let type: String
    let createdAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(content, forKey: .content)
        try c.encode(type, forKey: .type)
        try c.encode(createdAt, forKey: .createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, content, type, createdAt
    }
}

private struct TaskSummary: Encodable {
    let _id: String
    let title: String
    let status: String
    let priority: String
    let createdAt: Int64
    let parentTask: String?
    let source: String
    let completedAt: Int64?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(title, forKey: .title)
        try c.encode(status, forKey: .status)
        try c.encode(priority, forKey: .priority)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(parentTask, forKey: .parentTask)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, title, status, priority, createdAt, parentTask, source, completedAt
    }
}

private struct ScheduledJobSummary: Encodable {
    let _id: String
    let name: String
    let schedule: String
    let enabled: Bool
}

private struct WorkerSummary: Encodable {
    let _id: String
    let workerId: String
    let sessionLabel: String
    let status: String
}

private struct WakeBriefing: Encodable {
    let handoff: HandoffRecord?
    let recent: [MemorySummary]
    let stats: [String: Int]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(handoff, forKey: .handoff)
        try c.encode(recent, forKey: .recent)
        try c.encode(stats, forKey: .stats)
    }

    enum CodingKeys: String, CodingKey {
        case handoff, recent, stats
    }
}

private struct HealthCheck: Encodable {
    let ok: Bool
    let memories: Int
    let entities: Int
    let relations: Int
}

private struct SystemStatus: Encodable {
    let scheduledJobs: [ScheduledJobSummary]
    let tasks: [TaskSummary]
    let workers: [WorkerSummary]
}

private struct TaskProgress: Encodable {
    let parent: TaskSummary?
    let subtasks: [TaskSummary]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encode(subtasks, forKey: .subtasks)
    }

    enum CodingKeys: String, CodingKey {
        case parent, subtasks
    }
}

private struct TaskAuditResult: Encodable {
    let tasks: [TaskSummary]
    let count: Int
}

private struct WikiCoverageItem: Encodable {
    let slug: String
    let title: String
    let status: String?
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slug, forKey: .slug)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case slug, title, status, updatedAt
    }
}

private struct PrivateWriteResponse: Encodable {
    let saved: Bool
    let timestamp: String
}

private struct PrivateReadResponse: Encodable {
    let content: String
}

// MARK: - Row → summary conversions

private func handoffRowToRecord(_ row: HandoffRow) -> HandoffRecord {
    HandoffRecord(id: row.id, content: row.content, createdAt: row.createdAt)
}

private func memRowToSummary(_ row: MemoryRow) -> MemorySummary {
    MemorySummary(
        _id: row.id,
        content: row.content,
        type: row.type,
        createdAt: row.createdAt
    )
}

private func taskRowToSummary(_ row: TaskRow) -> TaskSummary {
    TaskSummary(
        _id: row.id,
        title: row.title,
        status: row.status,
        priority: row.priority,
        createdAt: row.createdAt,
        parentTask: row.parentTask,
        source: row.source,
        completedAt: row.completedAt
    )
}

private func scheduledJobRowToSummary(_ row: ScheduledJobRow) -> ScheduledJobSummary {
    ScheduledJobSummary(
        _id: row.id,
        name: row.name,
        schedule: row.schedule,
        enabled: row.enabled
    )
}

private func workerRowToSummary(_ row: WorkerRow) -> WorkerSummary {
    WorkerSummary(
        _id: row.id,
        workerId: row.workerId,
        sessionLabel: row.sessionLabel,
        status: row.status
    )
}

/// Build a MemoryResponse from a MemoryRow, using the shared parseTags helper.
/// Local to CompositeActions to avoid cross-file private-func conflicts.
private func memRowToResponseForComposite(_ row: MemoryRow) -> MemoryResponse {
    MemoryResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        content: row.content,
        type: row.type,
        tags: parseTags(row.tagsJSON),
        source: row.source,
        importance: row.importance,
        l0: row.l0,
        l1: row.l1,
        accessCount: row.accessCount,
        lastAccessedAt: row.lastAccessedAt,
        status: row.status,
        supersededBy: row.supersededBy,
        revisionOf: row.revisionOf,
        revisionNote: row.revisionNote,
        validFrom: row.validFrom,
        validUntil: row.validUntil,
        project: row.project,
        topic: row.topic,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}

/// Escape a string for safe embedding into a JSON string literal.
private func jsonEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:   out.append(ch)
        }
    }
    return out
}

// MARK: - Composite actions

let compositeActions: [SonataAction] = [

    // mem_wake — morning briefing
    SonataAction(
        name: "mem_wake",
        description: "Morning briefing — last handoff, recent memory activity, and counts.",
        group: "/api",
        path: "/wake",
        method: .get,
        params: [],
        mcpOnly: true,
        handler: { ctx in
            do {
                let handoff = try await ctx.dbPool.read { db in
                    try HandoffRow.fetchOne(
                        db,
                        sql: "SELECT * FROM handoffs ORDER BY createdAt DESC LIMIT 1"
                    )
                }
                let recent = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchAll(
                        db,
                        sql: "SELECT * FROM memories ORDER BY createdAt DESC LIMIT 5"
                    )
                }
                let memoriesCount = try await ctx.dbPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0
                }
                let entitiesCount = try await ctx.dbPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entities") ?? 0
                }

                return WakeBriefing(
                    handoff: handoff.map(handoffRowToRecord),
                    recent: recent.map(memRowToSummary),
                    stats: ["memories": memoriesCount, "entities": entitiesCount]
                )
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // mem_health — system health check
    SonataAction(
        name: "mem_health",
        description: "Check memory system backend health — DB connectivity and key table counts.",
        group: "/api",
        path: "/health-check",
        method: .get,
        params: [],
        mcpOnly: true,
        handler: { ctx in
            do {
                let memories = try await ctx.dbPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0
                }
                let entities = try await ctx.dbPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entities") ?? 0
                }
                let relations = try await ctx.dbPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relations") ?? 0
                }
                return HealthCheck(ok: true, memories: memories, entities: entities, relations: relations)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // mem_status — system overview
    SonataAction(
        name: "mem_status",
        description: "System overview — enabled scheduled jobs, pending+active tasks, all workers.",
        group: "/api",
        path: "/system-status",
        method: .get,
        params: [],
        mcpOnly: true,
        handler: { ctx in
            do {
                let jobs = try await ctx.dbPool.read { db in
                    try ScheduledJobRow.fetchAll(
                        db,
                        sql: "SELECT * FROM scheduledJobs WHERE enabled = 1 ORDER BY name"
                    )
                }
                let tasks = try await ctx.dbPool.read { db in
                    try TaskRow.fetchAll(
                        db,
                        sql: "SELECT * FROM tasks WHERE status IN ('pending','active') ORDER BY createdAt DESC LIMIT 20"
                    )
                }
                let workers = try await ctx.dbPool.read { db in
                    try WorkerRow.fetchAll(
                        db,
                        sql: "SELECT * FROM workers ORDER BY registeredAt DESC"
                    )
                }
                return SystemStatus(
                    scheduledJobs: jobs.map(scheduledJobRowToSummary),
                    tasks: tasks.map(taskRowToSummary),
                    workers: workers.map(workerRowToSummary)
                )
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // mem_task_progress — check parent + subtasks
    SonataAction(
        name: "mem_task_progress",
        description: "Check progress on a parent task and all its subtasks.",
        group: "/api",
        path: "/task-progress",
        method: .get,
        params: [
            ActionParam("task_id", .string, required: true, description: "Parent task ID"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let id = try ctx.params.require("task_id")
            do {
                let parent = try await ctx.dbPool.read { db in
                    try TaskRow.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id])
                }
                let subtasks = try await ctx.dbPool.read { db in
                    try TaskRow.fetchAll(
                        db,
                        sql: "SELECT * FROM tasks WHERE parentTask = ? ORDER BY createdAt",
                        arguments: [id]
                    )
                }
                return TaskProgress(
                    parent: parent.map(taskRowToSummary),
                    subtasks: subtasks.map(taskRowToSummary)
                )
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // mem_task_audit — check for stale/orphaned tasks
    SonataAction(
        name: "mem_task_audit",
        description: "Audit the last 200 tasks — surface stuck, orphaned, or long-running items.",
        group: "/api",
        path: "/task-audit",
        method: .get,
        params: [],
        mcpOnly: true,
        handler: { ctx in
            do {
                let tasks = try await ctx.dbPool.read { db in
                    try TaskRow.fetchAll(
                        db,
                        sql: "SELECT * FROM tasks ORDER BY createdAt DESC LIMIT 200"
                    )
                }
                let summaries = tasks.map(taskRowToSummary)
                return TaskAuditResult(tasks: summaries, count: summaries.count)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // mem_check — fact/contradiction check via FTS
    SonataAction(
        name: "mem_check",
        description: "Check a fact for contradictions against existing memories (FTS5).",
        group: "/api",
        path: "/check-fact",
        method: .get,
        params: [
            ActionParam("fact", .string, required: true, description: "Fact to check"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let fact = try ctx.params.require("fact")
            do {
                let rows = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchAll(
                        db,
                        sql: """
                        SELECT m.* FROM memories m
                        JOIN memories_fts fts ON fts.rowid = m.rowid
                        WHERE memories_fts MATCH ?
                        ORDER BY rank LIMIT 10
                        """,
                        arguments: [fact]
                    )
                }
                return rows.map(memRowToResponseForComposite)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // mem_curious — store a curiosity
    SonataAction(
        name: "mem_curious",
        description: "Jot down a curiosity or wondering for later exploration.",
        group: "/api",
        path: "/curious",
        method: .post,
        params: [
            ActionParam("thought", .string, required: true, description: "The curiosity"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let thought = try ctx.params.require("thought")
            let id = newUUID()
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO memories
                            (id, content, type, tags, source, importance,
                             validFrom, createdAt, updatedAt)
                        VALUES (?, ?, 'reflection', '["curiosity"]', 'sona', 3, ?, ?, ?)
                        """,
                        arguments: [id, thought, now, now, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // mem_think — trigger background thinking
    SonataAction(
        name: "mem_think",
        description: "Trigger background thinking — consolidate, enrich, reflect, hygiene, or free-form.",
        group: "/api",
        path: "/think",
        method: .post,
        params: [
            ActionParam("mode", .string, required: true, description: "Mode: consolidate, enrich, reflect, hygiene, curiosity, collision, compress, world-watch"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let mode = try ctx.params.require("mode")
            let id = newUUID()
            let now = nowMs()
            let jobName = "background-think-\(mode)"
            let promptJSON = "{\"mode\":\"\(jsonEscape(mode))\"}"
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO backgroundJobs (id, name, status, prompt, createdAt)
                        VALUES (?, ?, 'pending', ?, ?)
                        """,
                        arguments: [id, jobName, promptJSON, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // mem_wander — accidental adjacency (FTS on topic)
    SonataAction(
        name: "mem_wander",
        description: "Accidental adjacency — find unexpected connections starting from a topic.",
        group: "/api",
        path: "/wander",
        method: .get,
        params: [
            ActionParam("topic", .string, required: true, description: "Starting topic"),
            ActionParam("limit", .integer, description: "Max results (default 5)"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let topic = try ctx.params.require("topic")
            let limit = ctx.params.int("limit") ?? 5
            do {
                let rows = try await ctx.dbPool.read { db in
                    try MemoryRow.fetchAll(
                        db,
                        sql: """
                        SELECT m.* FROM memories m
                        JOIN memories_fts fts ON fts.rowid = m.rowid
                        WHERE memories_fts MATCH ?
                        ORDER BY rank LIMIT ?
                        """,
                        arguments: [topic, limit]
                    )
                }
                return rows.map(memRowToResponseForComposite)
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // mem_coverage — wiki coverage diagnostic
    // NOTE: wikiPages has no `status` column in the current schema; we surface
    // `pageType` as the `status` field to match the spirit of the planning doc.
    SonataAction(
        name: "mem_coverage",
        description: "Wiki coverage diagnostic — list all wiki pages with type and last-updated timestamps.",
        group: "/api",
        path: "/coverage",
        method: .get,
        params: [],
        mcpOnly: true,
        handler: { ctx in
            do {
                let rows = try await ctx.dbPool.read { db -> [Row] in
                    try Row.fetchAll(
                        db,
                        sql: "SELECT slug, title, pageType, updatedAt FROM wikiPages ORDER BY slug"
                    )
                }
                return rows.map { row -> WikiCoverageItem in
                    let slug: String = row["slug"] ?? ""
                    let title: String = row["title"] ?? ""
                    let pageType: String? = row["pageType"]
                    let updatedAt: Int64 = row["updatedAt"] ?? 0
                    return WikiCoverageItem(
                        slug: slug,
                        title: title,
                        status: pageType,
                        updatedAt: updatedAt
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // mem_private — append to local private journal
    SonataAction(
        name: "mem_private",
        description: "Append a private journal entry (filesystem-only, not stored in DB).",
        group: "/api",
        path: "/private",
        method: .post,
        params: [
            ActionParam("thought", .string, required: true, description: "Journal entry"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let thought = try ctx.params.require("thought")
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = "\n---\n*\(timestamp)*\n\n\(thought)\n"
            let journalPath = NSString("~/.sonata/private/journal.md").expandingTildeInPath

            // Ensure parent directory exists
            let dir = (journalPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            // Create file if missing
            if !FileManager.default.fileExists(atPath: journalPath) {
                FileManager.default.createFile(atPath: journalPath, contents: Data(), attributes: nil)
            }

            guard let data = entry.data(using: .utf8) else {
                throw ActionError.custom("Encoding failed", .internalServerError)
            }
            guard let handle = FileHandle(forWritingAtPath: journalPath) else {
                throw ActionError.custom("Unable to open journal for writing", .internalServerError)
            }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()

            return PrivateWriteResponse(saved: true, timestamp: timestamp)
        }
    ),

    // mem_private_read — read last chunk of private journal
    SonataAction(
        name: "mem_private_read",
        description: "Read the private journal (last 5000 characters).",
        group: "/api",
        path: "/private-read",
        method: .get,
        params: [],
        mcpOnly: true,
        handler: { _ in
            let journalPath = NSString("~/.sonata/private/journal.md").expandingTildeInPath
            let content = (try? String(contentsOfFile: journalPath, encoding: .utf8)) ?? ""
            let suffix = content.suffix(5000)
            return PrivateReadResponse(content: String(suffix))
        }
    ),

    // mem_visualize — queue image generation as a deferred job.
    // NOTE: This is a deferred-execution stub. Instead of calling OpenAI directly,
    // we enqueue a backgroundJob with name='visualize' carrying the params in the
    // `prompt` column as JSON. A background worker is expected to pick it up.
    SonataAction(
        name: "mem_visualize",
        description: "Queue an image-generation job. Worker picks it up, calls DALL-E, stores file path.",
        group: "/api",
        path: "/visualize",
        method: .post,
        params: [
            ActionParam("description", .string, required: true, description: "Image description"),
            ActionParam("size", .string, description: "Size: 1024x1024, 1792x1024, 1024x1792 (default 1024x1024)"),
            ActionParam("style", .string, description: "Style: vivid, natural (default vivid)"),
            ActionParam("quality", .string, description: "Quality: standard, hd (default standard)"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let description = try ctx.params.require("description")
            let size = ctx.params.string("size") ?? "1024x1024"
            let style = ctx.params.string("style") ?? "vivid"
            let quality = ctx.params.string("quality") ?? "standard"
            let id = newUUID()
            let now = nowMs()
            let promptJSON = """
            {"description":"\(jsonEscape(description))","size":"\(jsonEscape(size))","style":"\(jsonEscape(style))","quality":"\(jsonEscape(quality))"}
            """
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO backgroundJobs (id, name, status, prompt, createdAt)
                        VALUES (?, 'visualize', 'pending', ?, ?)
                        """,
                        arguments: [id, promptJSON, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // mem_spawn — spawn a worker task via the tasks queue
    SonataAction(
        name: "mem_spawn",
        description: "Spawn a Claude worker by enqueueing a task.",
        group: "/api",
        path: "/spawn",
        method: .post,
        params: [
            ActionParam("task", .string, required: true, description: "Task prompt"),
            ActionParam("model", .string, description: "Model: opus, sonnet (default sonnet)"),
            ActionParam("dir", .string, description: "Working directory (default ~/memory)"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let task = try ctx.params.require("task")
            let model = ctx.params.string("model") ?? "sonnet"
            let dir = ctx.params.string("dir") ?? "\(NSHomeDirectory())/memory"
            let id = newUUID()
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO tasks
                            (id, title, status, priority, prompt,
                             workingDir, model, blockedBy, originalBlockedBy,
                             source, outputFiles, tags, retryCount, tools,
                             createdAt, updatedAt)
                        VALUES (?, 'spawn', 'pending', 'normal', ?,
                                ?, ?, '[]', '[]',
                                'spawn', '[]', '[]', 0, '[]',
                                ?, ?)
                        """,
                        arguments: [id, task, dir, model, now, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // mem_embed_backfill — queue embedding backfill job
    SonataAction(
        name: "mem_embed_backfill",
        description: "Queue a background job to generate embeddings for memories missing them.",
        group: "/api",
        path: "/embed-backfill",
        method: .post,
        params: [
            ActionParam("count", .integer, description: "Max memories to process (default 100)"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let count = ctx.params.int("count") ?? 100
            let id = newUUID()
            let now = nowMs()
            let promptJSON = "{\"count\":\(count)}"
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO backgroundJobs (id, name, status, prompt, createdAt)
                        VALUES (?, 'embed-backfill', 'pending', ?, ?)
                        """,
                        arguments: [id, promptJSON, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // mem_ingest_sessions — queue session-ingest job
    SonataAction(
        name: "mem_ingest_sessions",
        description: "Queue a background job to ingest new Claude Code session transcripts.",
        group: "/api",
        path: "/ingest-sessions",
        method: .post,
        params: [
            ActionParam("project", .string, description: "Filter by project"),
            ActionParam("dry_run", .boolean, description: "Preview without storing"),
            ActionParam("force", .boolean, description: "Re-ingest already-processed sessions"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let project = ctx.params.string("project")
            let dryRun = ctx.params.bool("dry_run") ?? false
            let force = ctx.params.bool("force") ?? false

            var parts: [String] = []
            if let p = project { parts.append("\"project\":\"\(jsonEscape(p))\"") }
            parts.append("\"dry_run\":\(dryRun)")
            parts.append("\"force\":\(force)")
            let promptJSON = "{" + parts.joined(separator: ",") + "}"

            let id = newUUID()
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO backgroundJobs (id, name, status, prompt, createdAt)
                        VALUES (?, 'ingest-sessions', 'pending', ?, ?)
                        """,
                        arguments: [id, promptJSON, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),

    // mem_wiki_enrich — queue wiki-enrichment job for a planning doc
    SonataAction(
        name: "mem_wiki_enrich",
        description: "Queue a planning doc for wiki enrichment via background job.",
        group: "/api",
        path: "/wiki-enrich",
        method: .post,
        params: [
            ActionParam("doc_path", .string, required: true, description: "Path to the doc to enrich"),
            ActionParam("namespace", .string, description: "Wiki namespace"),
        ],
        mcpOnly: true,
        handler: { ctx in
            let docPath = try ctx.params.require("doc_path")
            let namespace = ctx.params.string("namespace")
            var parts: [String] = ["\"docPath\":\"\(jsonEscape(docPath))\""]
            if let ns = namespace { parts.append("\"namespace\":\"\(jsonEscape(ns))\"") }
            let promptJSON = "{" + parts.joined(separator: ",") + "}"

            let id = newUUID()
            let now = nowMs()
            do {
                try await ctx.dbPool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO backgroundJobs (id, name, status, prompt, createdAt)
                        VALUES (?, 'wiki-enrich', 'pending', ?, ?)
                        """,
                        arguments: [id, promptJSON, now]
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
            return StoreResponse(id: id)
        }
    ),
]
