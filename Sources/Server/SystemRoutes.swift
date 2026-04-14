import Foundation
import Hummingbird
import GRDB

// MARK: - Response Types

struct PingResponse: Encodable {
    let pong = true
}

struct SystemStatusResponse: Encodable {
    let status = "ok"
    let memoryCount: Int
    let entityCount: Int
    let pendingTasks: Int
    let unreadEmails: Int
    let nextCalendarEvent: NextEventInfo?
    let workerCount: Int
    let backgroundJobs: BackgroundJobSummary
}

struct NextEventInfo: Encodable {
    let id: String
    let title: String
    let startTime: Int64
}

struct BackupResponse: Encodable {
    let success: Bool
    let path: String
    let sizeMB: String
}

struct BackgroundJobSummary: Encodable {
    let pending: Int
    let running: Int
    let completed: Int
    let failed: Int
}

// MARK: - Route Registration

public func registerSystemRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    // GET /api/ping
    router.get("/api/ping") { _, _ -> Response in
        jsonResponse(PingResponse())
    }

    // GET /api/status
    router.get("/api/status") { _, _ -> Response in
        do {
            let result = try await dbPool.read { db -> SystemStatusResponse in
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

            return jsonResponse(result)
        } catch {
            return errorResponse("Database error: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // POST /api/backup — trigger an immediate full backup (local + S3)
    router.post("/api/backup") { _, _ -> Response in
        let backupManager = BackupManager(dbPool: dbPool)
        await backupManager.runBackup()
        let backupPath = "\(DatabaseManager.dataDirectory)/backups/sonata-latest.db"
        let size = (try? FileManager.default.attributesOfItem(atPath: backupPath)[.size] as? Int64) ?? 0
        let sizeMB = String(format: "%.1f", Double(size) / 1_048_576)
        return jsonResponse(BackupResponse(success: true, path: backupPath, sizeMB: sizeMB))
    }
}
