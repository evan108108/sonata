import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definitions for bare /api system routes.
// Handler logic duplicated from SystemRoutes.swift.

private struct DeployProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

private func runDeployProcess(
    executable: String,
    arguments: [String],
    cwd: String?,
    timeoutSeconds: Int
) -> DeployProcessResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    if let cwd = cwd {
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe

    do {
        try p.run()
    } catch {
        return DeployProcessResult(
            status: -1, stdout: "",
            stderr: "spawn failed: \(error.localizedDescription)",
            timedOut: false
        )
    }

    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while p.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }

    var timedOut = false
    if p.isRunning {
        timedOut = true
        p.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        if p.isRunning { p.interrupt() }
    }

    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
    let outStr = String(data: outData, encoding: .utf8) ?? ""
    let errStr = String(data: errData, encoding: .utf8) ?? ""

    return DeployProcessResult(
        status: p.terminationStatus,
        stdout: outStr,
        stderr: errStr,
        timedOut: timedOut
    )
}

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

    // POST /api/system/deploy — build, copy binary, codesign Sonata app (does not restart)
    SonataAction(
        name: "system_deploy",
        description: "Build Sonata from source, copy the binary to /Applications/Sonata.app, and codesign. Does not restart the app — user restarts manually.",
        group: "/api",
        path: "/system/deploy",
        method: .post,
        params: [],
        handler: { _ in
            let home = NSHomeDirectory()
            let sourceDir = "\(home)/memory/Sonata"
            let binarySrc = "\(sourceDir)/.build/arm64-apple-macosx/debug/Sonata"
            let binaryDst = "/Applications/Sonata.app/Contents/MacOS/Sonata"
            let appPath = "/Applications/Sonata.app"

            // 1. swift build (120s timeout)
            let build = await Task.detached {
                runDeployProcess(
                    executable: "/usr/bin/env",
                    arguments: ["swift", "build"],
                    cwd: sourceDir,
                    timeoutSeconds: 120
                )
            }.value

            if build.timedOut {
                return DeployResponse(
                    success: false, step: "build",
                    error: "swift build timed out after 120s",
                    message: nil
                )
            }
            if build.status != 0 {
                return DeployResponse(
                    success: false, step: "build",
                    error: "swift build failed (exit \(build.status))\nstdout:\n\(build.stdout)\nstderr:\n\(build.stderr)",
                    message: nil
                )
            }

            // 2. Copy binary
            do {
                if FileManager.default.fileExists(atPath: binaryDst) {
                    try FileManager.default.removeItem(atPath: binaryDst)
                }
                try FileManager.default.copyItem(atPath: binarySrc, toPath: binaryDst)
            } catch {
                return DeployResponse(
                    success: false, step: "copy",
                    error: "copy failed: \(error.localizedDescription)",
                    message: nil
                )
            }

            // 3. codesign (30s timeout)
            let sign = await Task.detached {
                runDeployProcess(
                    executable: "/usr/bin/codesign",
                    arguments: ["--force", "--no-strict", "--sign", "-", appPath],
                    cwd: nil,
                    timeoutSeconds: 30
                )
            }.value

            if sign.status != 0 {
                return DeployResponse(
                    success: false, step: "codesign",
                    error: "codesign failed (exit \(sign.status))\n\(sign.stderr)",
                    message: nil
                )
            }

            return DeployResponse(
                success: true, step: "done",
                error: nil,
                message: "Deployment complete. Restart Sonata to pick up the new binary — e.g. osascript -e 'tell application \"Sonata\" to quit' && open /Applications/Sonata.app"
            )
        }
    ),
]
