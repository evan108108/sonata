import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for bare /api system routes.
// Handler logic duplicated from SystemRoutes.swift.

let systemActions: [SonataAction] = [

    // GET /api/ping
    SonataAction(
        name: "system_ping",
        description: "Service ping — returns pong=true.",
        group: "/api",
        path: "/ping",
        method: .get,
        params: [],
        handler: { _ in
            PingResponse()
        }
    ),

    // GET /api/status
    SonataAction(
        name: "system_status",
        description: "System status — counts of memories, entities, pending tasks, unread emails, next calendar event, workers, and background job summary.",
        group: "/api",
        path: "/status",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                return try await ctx.dbPool.read { db -> SystemStatusResponse in
                    let memRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM memories")!
                    let memoryCount: Int = memRow["cnt"]

                    let entRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM entities")!
                    let entityCount: Int = entRow["cnt"]

                    let taskRow = try Row.fetchOne(db, sql: """
                        SELECT COUNT(*) AS cnt FROM tasks WHERE status = 'pending'
                    """)!
                    let pendingTasks: Int = taskRow["cnt"]

                    let emailRow = try Row.fetchOne(db, sql: """
                        SELECT COUNT(*) AS cnt FROM emails WHERE status = 'unread'
                    """)!
                    let unreadEmails: Int = emailRow["cnt"]

                    // Next upcoming calendar event
                    let now = nowMs()
                    let calRow = try Row.fetchOne(db, sql: """
                        SELECT id, title, scheduledAt FROM calendarEvents
                        WHERE scheduledAt > ? AND enabled = 1 ORDER BY scheduledAt ASC LIMIT 1
                    """, arguments: [now])
                    let nextEvent: NextEventInfo? = calRow.map { r in
                        NextEventInfo(
                            id: r["id"],
                            title: r["title"],
                            startTime: r["scheduledAt"]
                        )
                    }

                    let workerRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM workers")!
                    let workerCount: Int = workerRow["cnt"]

                    // Background job summary by status
                    let bgRows = try Row.fetchAll(db, sql: """
                        SELECT status, COUNT(*) AS cnt FROM backgroundJobs GROUP BY status
                    """)
                    var bgMap: [String: Int] = [:]
                    for r in bgRows {
                        let s: String = r["status"]
                        let c: Int = r["cnt"]
                        bgMap[s] = c
                    }
                    let bgSummary = BackgroundJobSummary(
                        pending: bgMap["pending"] ?? 0,
                        running: bgMap["running"] ?? 0,
                        completed: bgMap["completed"] ?? 0,
                        failed: bgMap["failed"] ?? 0
                    )

                    return SystemStatusResponse(
                        memoryCount: memoryCount,
                        entityCount: entityCount,
                        pendingTasks: pendingTasks,
                        unreadEmails: unreadEmails,
                        nextCalendarEvent: nextEvent,
                        workerCount: workerCount,
                        backgroundJobs: bgSummary
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // POST /api/backup — trigger an immediate full backup (local + S3)
    SonataAction(
        name: "system_backup",
        description: "Trigger an immediate full backup (local + S3).",
        group: "/api",
        path: "/backup",
        method: .post,
        params: [],
        handler: { ctx in
            let backupManager = BackupManager(dbPool: ctx.dbPool)
            await backupManager.runBackup()
            let backupPath = "\(DatabaseManager.dataDirectory)/backups/sonata-latest.db"
            let size = (try? FileManager.default.attributesOfItem(atPath: backupPath)[.size] as? Int64) ?? 0
            let sizeMB = String(format: "%.1f", Double(size) / 1_048_576)
            return BackupResponse(success: true, path: backupPath, sizeMB: sizeMB)
        }
    ),
]
