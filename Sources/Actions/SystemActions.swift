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
            // Read external-bridge count outside the dbPool block — the registry
            // is in-memory and entirely independent of the SQLite connection.
            let externalBridgeCount = ExternalBridgeRegistry.shared.currentCount()
            do {
                return try await ctx.dbPool.read { db -> SystemStatusResponse in
                    let memRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM memories")!
                    let memoryCount: Int = memRow["cnt"]

                    let memoryTypeRows = try Row.fetchAll(db, sql: """
                        SELECT type, COUNT(*) AS cnt FROM memories
                        GROUP BY type
                    """)
                    var memoriesByType: [String: Int] = [:]
                    for r in memoryTypeRows {
                        let t: String = r["type"]
                        let c: Int = r["cnt"]
                        memoriesByType[t] = c
                    }

                    let wikiRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM wikiPages")!
                    let wikiPageCount: Int = wikiRow["cnt"]

                    let entRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM entities")!
                    let entityCount: Int = entRow["cnt"]

                    let entityTypeRows = try Row.fetchAll(db, sql: """
                        SELECT type, COUNT(*) AS cnt FROM entities
                        GROUP BY type
                    """)
                    var entitiesByType: [String: Int] = [:]
                    for r in entityTypeRows {
                        let t: String = r["type"]
                        let c: Int = r["cnt"]
                        entitiesByType[t] = c
                    }

                    let taskRow = try Row.fetchOne(db, sql: """
                        SELECT COUNT(*) AS cnt FROM tasks WHERE status = 'pending'
                    """)!
                    let pendingTasks: Int = taskRow["cnt"]

                    let taskStatusRows = try Row.fetchAll(db, sql: """
                        SELECT status, COUNT(*) AS cnt FROM tasks
                        GROUP BY status
                    """)
                    var tasksByStatus: [String: Int] = [:]
                    for r in taskStatusRows {
                        let s: String = r["status"]
                        let c: Int = r["cnt"]
                        tasksByStatus[s] = c
                    }
                    // Stuck-task counts (failed + blocked) exclude items the user has
                    // acknowledged on the dashboard's attention card. tasksByStatus is
                    // left as the raw breakdown so the Tasks tab still sees the whole
                    // history; only the attention surfaces filter on acknowledgedAt.
                    let failedRow = try Row.fetchOne(db, sql: """
                        SELECT COUNT(*) AS cnt FROM tasks
                        WHERE status = 'failed' AND acknowledgedAt IS NULL
                    """)!
                    let failedTasks: Int = failedRow["cnt"]

                    // Already-blocked pending tasks: blockedBy is a non-empty JSON array.
                    let blockedRow = try Row.fetchOne(db, sql: """
                        SELECT COUNT(*) AS cnt FROM tasks
                        WHERE status = 'pending'
                          AND acknowledgedAt IS NULL
                          AND blockedBy IS NOT NULL
                          AND blockedBy != '[]'
                          AND blockedBy != ''
                    """)!
                    let blockedTasks: Int = blockedRow["cnt"]

                    let emailRow = try Row.fetchOne(db, sql: """
                        SELECT COUNT(*) AS cnt FROM emails WHERE status = 'unread'
                    """)!
                    let unreadEmails: Int = emailRow["cnt"]

                    let emailStatusRows = try Row.fetchAll(db, sql: """
                        SELECT status, COUNT(*) AS cnt FROM emails
                        GROUP BY status
                    """)
                    var emailsByStatus: [String: Int] = [:]
                    for r in emailStatusRows {
                        let s: String = r["status"]
                        let c: Int = r["cnt"]
                        emailsByStatus[s] = c
                    }

                    // Upcoming calendar events: top 3 by scheduledAt ASC. The first row is
                    // also surfaced as `nextCalendarEvent` for backward compatibility with
                    // the existing Next Event StatCard.
                    let now = nowMs()
                    let upcomingRows = try Row.fetchAll(db, sql: """
                        SELECT id, title, scheduledAt FROM calendarEvents
                        WHERE scheduledAt > ? AND enabled = 1 ORDER BY scheduledAt ASC LIMIT 3
                    """, arguments: [now])
                    let upcomingEvents: [NextEventInfo] = upcomingRows.map { r in
                        NextEventInfo(
                            id: r["id"],
                            title: r["title"],
                            startTime: r["scheduledAt"]
                        )
                    }
                    let nextEvent: NextEventInfo? = upcomingEvents.first

                    // Worker liveness: a row is "alive" only with fresh heartbeat (<90s)
                    // and a non-offline status. A row with status='idle' but a stale
                    // heartbeat is treated as 'stale' (zombie).
                    let staleCutoff = nowMs() - 90_000

                    // Effective-status breakdown: idle/busy/starting/draining/stale/offline.
                    let workerStatusRows = try Row.fetchAll(db, sql: """
                        SELECT
                            CASE
                                WHEN status = 'offline' THEN 'offline'
                                WHEN lastHeartbeat < ? THEN 'stale'
                                ELSE status
                            END AS effectiveStatus,
                            COUNT(*) AS cnt
                        FROM workers
                        GROUP BY effectiveStatus
                    """, arguments: [staleCutoff])
                    var workersByStatus: [String: Int] = [:]
                    for r in workerStatusRows {
                        let s: String = r["effectiveStatus"]
                        let c: Int = r["cnt"]
                        workersByStatus[s] = c
                    }

                    // Alive = everything except offline and stale.
                    let workerCount = workersByStatus
                        .filter { $0.key != "offline" && $0.key != "stale" }
                        .values.reduce(0, +)

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
                        memoriesByType: memoriesByType,
                        wikiPageCount: wikiPageCount,
                        entityCount: entityCount,
                        entitiesByType: entitiesByType,
                        pendingTasks: pendingTasks,
                        tasksByStatus: tasksByStatus,
                        failedTasks: failedTasks,
                        blockedTasks: blockedTasks,
                        unreadEmails: unreadEmails,
                        emailsByStatus: emailsByStatus,
                        nextCalendarEvent: nextEvent,
                        upcomingCalendarEvents: upcomingEvents,
                        workerCount: workerCount,
                        workersByStatus: workersByStatus,
                        externalBridgeCount: externalBridgeCount,
                        backgroundJobs: bgSummary
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/recent_activity — curated cross-table activity feed (last 24h, capped at 20)
    SonataAction(
        name: "system_recent_activity",
        description: "Curated recent activity feed: worker completions, email replies, scheduled-job runs, calendar firings, and background-thinking reflections from the last 24h. Returns up to 20 items, deduped within 5-minute windows.",
        group: "/api",
        path: "/recent_activity",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                return try await ctx.dbPool.read { db -> RecentActivityResponse in
                    let now = nowMs()
                    let cutoff = now - 24 * 60 * 60 * 1000
                    var raw: [ActivityItem] = []

                    // Worker events: only completed, only types that represent real work.
                    // Filter out heartbeat/check noise events defensively even though the
                    // current bridge doesn't insert them as workerEvents — guard against
                    // future event types polluting the feed.
                    let weRows = try Row.fetchAll(db, sql: """
                        SELECT we.id, we.type, we.payload, we.assignedTo, we.completedAt,
                               we.createdAt, w.sessionLabel
                        FROM workerEvents we
                        LEFT JOIN workers w ON w.workerId = we.assignedTo
                        WHERE we.status = 'completed'
                          AND we.completedAt IS NOT NULL
                          AND we.completedAt >= ?
                          AND we.type NOT IN ('heartbeat', 'check', 'ping')
                        ORDER BY we.completedAt DESC
                        LIMIT 60
                    """, arguments: [cutoff])
                    for r in weRows {
                        let id: String = r["id"]
                        let type: String = r["type"]
                        let payloadStr: String = r["payload"]
                        let assignedTo: String? = r["assignedTo"]
                        let completedAt: Int64 = r["completedAt"]
                        let createdAt: Int64 = r["createdAt"]
                        let label: String? = r["sessionLabel"]

                        // Pull a friendly title out of the payload JSON when present;
                        // fall back to the event type so the row is never blank.
                        var title = type
                        if let data = payloadStr.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if let t = obj["title"] as? String, !t.isEmpty {
                                title = t
                            } else if let s = obj["summary"] as? String, !s.isEmpty {
                                title = s
                            }
                        }
                        title = String(title.prefix(120))

                        let durSec = max(0, (completedAt - createdAt) / 1000)
                        let workerLabel = label ?? assignedTo ?? "worker"
                        let subtitle = "\(workerLabel) · \(durSec)s"

                        raw.append(ActivityItem(
                            id: id,
                            type: "worker_completed",
                            title: title,
                            subtitle: subtitle,
                            timestamp: completedAt,
                            icon: "checkmark.circle.fill",
                            collapsedCount: nil
                        ))
                    }

                    // Email replies sent in the window.
                    let emailRows = try Row.fetchAll(db, sql: """
                        SELECT id, subject, fromAddr, repliedAt
                        FROM emails
                        WHERE status = 'replied' AND repliedAt IS NOT NULL AND repliedAt >= ?
                        ORDER BY repliedAt DESC
                        LIMIT 40
                    """, arguments: [cutoff])
                    for r in emailRows {
                        let id: String = r["id"]
                        let subject: String = r["subject"]
                        let fromAddr: String = r["fromAddr"]
                        let repliedAt: Int64 = r["repliedAt"]

                        // "Allison Formicola <allison@enginable.com>" → "allison"
                        var handle = fromAddr
                        if let lt = handle.firstIndex(of: "<"),
                           let gt = handle.firstIndex(of: ">"),
                           lt < gt {
                            handle = String(handle[handle.index(after: lt)..<gt])
                        }
                        if let at = handle.firstIndex(of: "@") {
                            handle = String(handle[..<at])
                        }
                        handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)

                        raw.append(ActivityItem(
                            id: id,
                            type: "email_replied",
                            title: String(subject.prefix(120)),
                            subtitle: "Replied to \(handle)",
                            timestamp: repliedAt,
                            icon: "envelope.fill",
                            collapsedCount: nil
                        ))
                    }

                    // Scheduled jobs: lastRunAt is REAL (ms epoch as Double).
                    let jobRows = try Row.fetchAll(db, sql: """
                        SELECT id, name, lastRunAt, lastResult, lastExitCode
                        FROM scheduledJobs
                        WHERE lastRunAt IS NOT NULL AND lastRunAt >= ?
                        ORDER BY lastRunAt DESC
                        LIMIT 40
                    """, arguments: [Double(cutoff)])
                    for r in jobRows {
                        let id: String = r["id"]
                        let name: String = r["name"]
                        let lastRunAt: Double = r["lastRunAt"]
                        let lastResult: String? = r["lastResult"]
                        let lastExitCode: Double? = r["lastExitCode"]

                        let failed = (lastExitCode ?? 0) != 0
                        let result = lastResult.flatMap { $0.isEmpty ? nil : $0 } ?? "ok"
                        let resultTrimmed = String(result.prefix(80))
                        let subtitle = failed
                            ? "(failed) last result: \(resultTrimmed)"
                            : "last result: \(resultTrimmed)"

                        raw.append(ActivityItem(
                            id: id,
                            type: "scheduled_job_run",
                            title: name,
                            subtitle: subtitle,
                            timestamp: Int64(lastRunAt),
                            icon: "calendar.circle.fill",
                            collapsedCount: nil
                        ))
                    }

                    // Calendar events that fired.
                    let calRows = try Row.fetchAll(db, sql: """
                        SELECT id, title, lastRunAt, lastRunStatus
                        FROM calendarEvents
                        WHERE lastRunAt IS NOT NULL AND lastRunAt >= ? AND runCount > 0
                        ORDER BY lastRunAt DESC
                        LIMIT 40
                    """, arguments: [cutoff])
                    for r in calRows {
                        let id: String = r["id"]
                        let title: String = r["title"]
                        let lastRunAt: Int64 = r["lastRunAt"]
                        let lastRunStatus: String? = r["lastRunStatus"]
                        raw.append(ActivityItem(
                            id: id,
                            type: "calendar_event_fired",
                            title: String(title.prefix(120)),
                            subtitle: "last status: \(lastRunStatus ?? "—")",
                            timestamp: lastRunAt,
                            icon: "calendar.badge.checkmark",
                            collapsedCount: nil
                        ))
                    }

                    // Background-thinking reflections.
                    let memRows = try Row.fetchAll(db, sql: """
                        SELECT id, l0, content, source, createdAt
                        FROM memories
                        WHERE type = 'reflection'
                          AND source LIKE 'background-thinking%'
                          AND createdAt >= ?
                        ORDER BY createdAt DESC
                        LIMIT 40
                    """, arguments: [cutoff])
                    for r in memRows {
                        let id: String = r["id"]
                        let l0: String? = r["l0"]
                        let content: String = r["content"]
                        let source: String? = r["source"]
                        let createdAt: Int64 = r["createdAt"]

                        let raw0 = (l0?.isEmpty == false ? l0! : content)
                        let title = String(raw0.prefix(80))
                        raw.append(ActivityItem(
                            id: id,
                            type: "background_thinking_output",
                            title: title,
                            subtitle: source ?? "background-thinking",
                            timestamp: createdAt,
                            icon: "brain",
                            collapsedCount: nil
                        ))
                    }

                    // Sort newest first across all sources.
                    raw.sort { $0.timestamp > $1.timestamp }

                    // Collapse same-(type, source-key) items within 5 min into a single
                    // entry titled "<original> + N more". The "source key" varies by
                    // type — for worker rows it's the worker label embedded in the
                    // subtitle; for emails it's the recipient handle; for jobs and
                    // calendar events it's the title. Use the subtitle for worker rows
                    // and the title for the rest as a stable bucket key.
                    let windowMs: Int64 = 5 * 60 * 1000
                    var collapsed: [ActivityItem] = []
                    var lastByBucket: [String: Int] = [:]   // bucket → index in collapsed
                    var lastTsByBucket: [String: Int64] = [:]

                    for item in raw {
                        let bucketKey: String
                        switch item.type {
                        case "worker_completed":
                            // Bucket by worker label (everything before " · " in subtitle).
                            let workerKey = item.subtitle.split(separator: "·", maxSplits: 1).first
                                .map { $0.trimmingCharacters(in: .whitespaces) } ?? item.subtitle
                            bucketKey = "\(item.type)|\(workerKey)"
                        case "email_replied":
                            bucketKey = "\(item.type)|\(item.subtitle)"
                        default:
                            bucketKey = "\(item.type)|\(item.title)"
                        }

                        if let idx = lastByBucket[bucketKey],
                           let lastTs = lastTsByBucket[bucketKey],
                           lastTs - item.timestamp <= windowMs {
                            // Within window: roll into the existing (newer) entry.
                            let existing = collapsed[idx]
                            let newCount = (existing.collapsedCount ?? 1) + 1
                            // Strip any prior "+ N more" suffix we appended on a previous merge.
                            var baseTitle = existing.title
                            if let range = baseTitle.range(of: " + ", options: .backwards),
                               baseTitle[range.upperBound...].hasSuffix(" more") {
                                baseTitle = String(baseTitle[..<range.lowerBound])
                            }
                            let newTitle = "\(baseTitle) + \(newCount - 1) more"
                            collapsed[idx] = ActivityItem(
                                id: existing.id,
                                type: existing.type,
                                title: newTitle,
                                subtitle: existing.subtitle,
                                timestamp: existing.timestamp,   // already the newest
                                icon: existing.icon,
                                collapsedCount: newCount
                            )
                        } else {
                            collapsed.append(item)
                            lastByBucket[bucketKey] = collapsed.count - 1
                            lastTsByBucket[bucketKey] = item.timestamp
                        }
                    }

                    let capped = Array(collapsed.prefix(20))
                    return RecentActivityResponse(items: capped, generatedAt: now)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/token_usage — today's spend, 7d daily totals, top consumer, anomaly flag
    SonataAction(
        name: "system_token_usage",
        description: "Token usage and spend rollup: today's USD spend (and total tokens), the last 7 days of daily totals, the top consumer (worker label or event type), and an anomaly flag when today's extrapolated spend is more than 2× yesterday's.",
        group: "/api",
        path: "/token_usage",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                return try await ctx.dbPool.read { db -> TokenUsageResponse in
                    let now = nowMs()
                    let cal = Calendar.current
                    let nowDate = Date(timeIntervalSince1970: TimeInterval(now) / 1000)
                    // Anchor "today" to the user's local midnight — the user reads
                    // the spend number on their own clock, not UTC.
                    let startOfToday = cal.startOfDay(for: nowDate)
                    let startOfTodayMs = Int64(startOfToday.timeIntervalSince1970 * 1000)
                    let sevenDaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
                    let sevenDaysAgoMs = Int64(sevenDaysAgo.timeIntervalSince1970 * 1000)
                    let yesterdayStartMs: Int64 = {
                        let d = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
                        return Int64(d.timeIntervalSince1970 * 1000)
                    }()

                    // Pull every completed/failed event with token data over the
                    // 7-day window once, then bucket in Swift. Cheaper and clearer
                    // than five SQL passes; 7 days × even a busy install fits in
                    // a few thousand rows.
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT we.id, we.type, we.totalTokens, we.model, we.completedAt,
                               we.assignedTo, w.sessionLabel
                        FROM workerEvents we
                        LEFT JOIN workers w ON w.workerId = we.assignedTo
                        WHERE we.completedAt IS NOT NULL
                          AND we.completedAt >= ?
                          AND we.totalTokens IS NOT NULL
                          AND we.totalTokens > 0
                    """, arguments: [sevenDaysAgoMs])

                    // Per-day buckets keyed by "YYYY-MM-DD" in the user's locale.
                    let dayFmt = DateFormatter()
                    dayFmt.dateFormat = "yyyy-MM-dd"
                    dayFmt.timeZone = .current

                    var dayTokens: [String: Int64] = [:]
                    var daySpend: [String: Double] = [:]
                    var todayTokens: Int64 = 0
                    var todaySpend: Double = 0
                    var yesterdaySpend: Double = 0
                    var consumerSpend: [String: Double] = [:]

                    for r in rows {
                        let totalTokens: Int64 = (r["totalTokens"] as? Int64) ?? 0
                        let completedAt: Int64 = (r["completedAt"] as? Int64) ?? 0
                        let model: String = (r["model"] as? String) ?? ModelPricing.defaultModel
                        let evType: String = (r["type"] as? String) ?? "unknown"
                        let label: String? = r["sessionLabel"]
                        let assignedTo: String? = r["assignedTo"]

                        let cost = ModelPricing.blendedCostUSD(model: model, totalTokens: totalTokens)
                        let date = Date(timeIntervalSince1970: TimeInterval(completedAt) / 1000)
                        let key = dayFmt.string(from: date)

                        dayTokens[key, default: 0] += totalTokens
                        daySpend[key, default: 0] += cost

                        if completedAt >= startOfTodayMs {
                            todayTokens += totalTokens
                            todaySpend += cost
                            // Top consumer is keyed by worker label when known,
                            // event type otherwise. The brief preferred worker label.
                            let consumer = label ?? assignedTo ?? evType
                            consumerSpend[consumer, default: 0] += cost
                        } else if completedAt >= yesterdayStartMs {
                            yesterdaySpend += cost
                        }
                    }

                    // Build the dailyTotals array oldest → newest, including zero days.
                    var dailyTotals: [DailyTokenTotal] = []
                    for offset in (0...6).reversed() {
                        guard let day = cal.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
                        let key = dayFmt.string(from: day)
                        dailyTotals.append(DailyTokenTotal(
                            date: key,
                            spendUSD: daySpend[key] ?? 0,
                            totalTokens: dayTokens[key] ?? 0
                        ))
                    }

                    let top = consumerSpend.max { $0.value < $1.value }
                    let topConsumer: TokenUsageTopConsumer? = top.map {
                        TokenUsageTopConsumer(label: $0.key, spendUSD: $0.value)
                    }

                    // Extrapolate today's spend to end-of-day so a busy morning
                    // doesn't trigger the anomaly flag at 6am. Floor at $1 of
                    // yesterday spend so we don't flag "200% of nothing."
                    let secondsIntoDay = max(60.0, nowDate.timeIntervalSince(startOfToday))
                    let dayShare = secondsIntoDay / 86_400.0
                    let projected = todaySpend / dayShare
                    var anomaly = TokenUsageAnomaly(flagged: false, ratio: nil)
                    if yesterdaySpend >= 1.0 {
                        let ratio = projected / yesterdaySpend
                        if ratio > 2.0 {
                            anomaly = TokenUsageAnomaly(flagged: true, ratio: ratio)
                        }
                    }

                    return TokenUsageResponse(
                        today: TokenUsageTodaySummary(spendUSD: todaySpend, totalTokens: todayTokens),
                        dailyTotals: dailyTotals,
                        topConsumer: topConsumer,
                        anomaly: anomaly,
                        generatedAt: now
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/plugins_status — plugin counts grouped by status
    SonataAction(
        name: "system_plugins",
        description: "Plugin state summary — total count and a breakdown by status (installed/running/disabled/error/...) from the plugins table.",
        group: "/api",
        path: "/plugins_status",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                return try await ctx.dbPool.read { db -> PluginStatusResponse in
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT status, COUNT(*) AS cnt FROM plugins GROUP BY status
                    """)
                    var byStatus: [String: Int] = [:]
                    for r in rows {
                        let s: String = r["status"]
                        let c: Int = r["cnt"]
                        byStatus[s] = c
                    }
                    let total = byStatus.values.reduce(0, +)
                    return PluginStatusResponse(
                        total: total,
                        byStatus: byStatus,
                        generatedAt: nowMs()
                    )
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/recent_thoughts — last 5 background-thinking memories within 24h
    SonataAction(
        name: "system_recent_thoughts",
        description: "Top 5 most-recent background-thinking memories from the last 24h. Each item includes the cron source name, an l0-derived title, and the full body for sheet display.",
        group: "/api",
        path: "/recent_thoughts",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                return try await ctx.dbPool.read { db -> RecentThoughtsResponse in
                    let now = nowMs()
                    let cutoff = now - 24 * 60 * 60 * 1000
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT id, l0, content, source, createdAt
                        FROM memories
                        WHERE source LIKE 'background-thinking%'
                          AND createdAt >= ?
                        ORDER BY createdAt DESC
                        LIMIT 5
                    """, arguments: [cutoff])

                    var items: [RecentThoughtItem] = []
                    for r in rows {
                        let id: String = r["id"]
                        let l0: String? = r["l0"]
                        let content: String = r["content"]
                        let source: String? = r["source"]
                        let createdAt: Int64 = r["createdAt"]

                        let raw0 = (l0?.isEmpty == false ? l0! : content)
                        let title = String(raw0.prefix(80))
                        items.append(RecentThoughtItem(
                            id: id,
                            title: title,
                            body: content,
                            source: source ?? "background-thinking",
                            timestamp: createdAt
                        ))
                    }
                    return RecentThoughtsResponse(items: items, generatedAt: now)
                }
            } catch {
                throw ActionError.database(error.localizedDescription)
            }
        }
    ),

    // GET /api/deadlines — universal deadline surface
    //
    // Two local sources only:
    //   1. tasks with dueAt <= end-of-today-local AND status NOT IN ('completed','cancelled')
    //   2. memories with type='deadline' OR tags containing 'deadline', AND validUntil <= end-of-today-local
    //
    // Project-specific deadline data (Scout RFPs, Linear issues, etc.) is the
    // responsibility of those projects to mirror INTO Sonata via tagged memories.
    SonataAction(
        name: "system_deadlines",
        description: "Universal deadlines for the Dashboard's Attention zone: tasks with dueAt today-or-overdue and memories tagged 'deadline' with validUntil today-or-overdue. Sorted ASC, capped at 20.",
        group: "/api",
        path: "/deadlines",
        method: .get,
        params: [],
        handler: { ctx in
            do {
                return try await ctx.dbPool.read { db -> DeadlinesResponse in
                    let now = nowMs()
                    // End of today, local timezone, exclusive — anything with
                    // dueAt strictly less than this falls within "today or earlier."
                    let cal = Calendar.current
                    let startOfToday = cal.startOfDay(for: Date())
                    let endOfTodayDate = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
                    let endOfTodayMs = Int64(endOfTodayDate.timeIntervalSince1970 * 1000)

                    var items: [DeadlineItem] = []

                    let taskRows = try Row.fetchAll(db, sql: """
                        SELECT id, title, dueAt, project, status
                        FROM tasks
                        WHERE dueAt IS NOT NULL
                          AND dueAt < ?
                          AND status NOT IN ('completed', 'cancelled')
                        ORDER BY dueAt ASC
                        LIMIT 20
                    """, arguments: [endOfTodayMs])
                    for r in taskRows {
                        let id: String = r["id"]
                        let title: String = r["title"]
                        let dueAt: Int64 = r["dueAt"]
                        let project: String? = r["project"]
                        let status: String? = r["status"]
                        // Subtitle: prefer "<project> · <status>" when project is set.
                        var parts: [String] = []
                        if let project, !project.isEmpty { parts.append(project) }
                        if let status, !status.isEmpty { parts.append(status) }
                        let subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
                        items.append(DeadlineItem(
                            id: id,
                            source: "task",
                            title: title,
                            subtitle: subtitle,
                            dueAt: dueAt
                        ))
                    }

                    // tags is a JSON array text column; matching `%"deadline"%`
                    // catches the canonical `["deadline", ...]` form. Type also
                    // accepted — the spec calls out both conventions.
                    let memRows = try Row.fetchAll(db, sql: """
                        SELECT id, l0, content, validUntil, type, project
                        FROM memories
                        WHERE validUntil IS NOT NULL
                          AND validUntil < ?
                          AND (type = 'deadline' OR tags LIKE '%"deadline"%')
                        ORDER BY validUntil ASC
                        LIMIT 20
                    """, arguments: [endOfTodayMs])
                    for r in memRows {
                        let id: String = r["id"]
                        let l0: String? = r["l0"]
                        let content: String = r["content"]
                        let validUntil: Int64 = r["validUntil"]
                        let memType: String? = r["type"]
                        let project: String? = r["project"]
                        let raw = (l0?.isEmpty == false ? l0! : content)
                        let title = String(raw.prefix(80))
                        var parts: [String] = []
                        if let project, !project.isEmpty { parts.append(project) }
                        if let memType, !memType.isEmpty { parts.append(memType) }
                        let subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
                        items.append(DeadlineItem(
                            id: id,
                            source: "memory",
                            title: title,
                            subtitle: subtitle,
                            dueAt: validUntil
                        ))
                    }

                    items.sort { $0.dueAt < $1.dueAt }
                    if items.count > 20 { items = Array(items.prefix(20)) }
                    return DeadlinesResponse(items: items, generatedAt: now)
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

            // 2b. Copy resource bundle (web/, mcp/, supervisor/, worker/) into TWO
            // paths inside the .app:
            //
            //   - Contents/Resources/  — what Bundle.main.resourcePath resolves to.
            //     The web-path resolver in SonataApp.swift falls back here when
            //     the dev source tree isn't present (e.g. on Scout). Stale
            //     Contents/Resources caused the Resume button to silently
            //     disappear on the Tasks tab.
            //   - Sonata_Sonata.bundle/  — what Bundle.module resolves to.
            //     ensureGlobalMCPServers() reads sonata-bridge.ts from
            //     Bundle.module on every Sonata startup and copies it to
            //     ~/.sonata/mcp/, which is the path workers actually load.
            //     Stale Sonata_Sonata.bundle made the Live Worker Monitoring v0
            //     bridge invisible to workers — telemetry never reached the DB,
            //     promptCacheStats stayed empty.
            //
            // Both paths must stay in sync on every deploy. On the dev machine
            // the source path at ~/memory/Sonata/Sources/Sonata/Resources takes
            // precedence for web (see resolver), so the Contents/Resources copy
            // is defensive there but load-bearing on Scout. The Sonata_Sonata.bundle
            // copy is load-bearing everywhere because Bundle.module has no
            // source-path fallback.
            let resourcesSrc = "\(sourceDir)/Sources/Sonata/Resources"
            for destPath in ["\(appPath)/Contents/Resources", "\(appPath)/Sonata_Sonata.bundle"] {
                let sync = await Task.detached {
                    runDeployProcess(
                        executable: "/usr/bin/rsync",
                        arguments: ["-a", "\(resourcesSrc)/", "\(destPath)/"],
                        cwd: nil,
                        timeoutSeconds: 60
                    )
                }.value
                if sync.status != 0 {
                    return DeployResponse(
                        success: false, step: "copy-resources",
                        error: "resources rsync to \(destPath) failed (exit \(sync.status))\n\(sync.stderr)",
                        message: nil
                    )
                }
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
