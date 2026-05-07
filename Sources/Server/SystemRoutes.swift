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
    let memoriesByType: [String: Int]  // breakdown by memory type (observation, decision, fact, ...)
    let wikiPageCount: Int             // wiki pages live in their own table; surfaced for context
    let entityCount: Int
    let entitiesByType: [String: Int] // breakdown by entity type (concept, tool, project, ...)
    let pendingTasks: Int
    let tasksByStatus: [String: Int]   // breakdown by task status (pending/completed/cancelled/failed/...)
    let failedTasks: Int               // tasks WHERE status = 'failed'
    let blockedTasks: Int              // pending tasks WHERE blockedBy is non-empty
    let unreadEmails: Int
    let emailsByStatus: [String: Int]  // breakdown by email status (unread/read/replied/error/...)
    let nextCalendarEvent: NextEventInfo?
    let upcomingCalendarEvents: [NextEventInfo]  // top 3 by scheduledAt ASC
    let workerCount: Int               // alive: not offline, fresh heartbeat
    let workersByStatus: [String: Int] // breakdown by effective status (idle/busy/starting/.../stale/offline)
    let externalBridgeCount: Int       // sonata-bridge.ts processes that aren't pool workers (e.g. claude/claude-patched sessions)
    let backgroundJobs: BackgroundJobSummary
}

struct NextEventInfo: Encodable {
    let id: String
    let title: String
    let startTime: Int64
}

struct PluginStatusResponse: Encodable {
    let total: Int
    let byStatus: [String: Int]   // installed/running/disabled/error/...
    let generatedAt: Int64
}

struct RecentThoughtItem: Encodable {
    let id: String
    let title: String      // l0 truncated to 80 chars (falls back to content prefix)
    let body: String       // full memory content for the sheet
    let source: String     // cron name like 'innerLife', 'curiosityGarden'
    let timestamp: Int64
}

struct RecentThoughtsResponse: Encodable {
    let items: [RecentThoughtItem]
    let generatedAt: Int64
}

struct DeadlineItem: Encodable {
    let id: String
    let source: String   // "task" | "memory"
    let title: String    // task title OR memory l0 truncated
    let subtitle: String?
    let dueAt: Int64
}

struct DeadlinesResponse: Encodable {
    let items: [DeadlineItem]
    let generatedAt: Int64
}

struct BackupResponse: Encodable {
    let success: Bool
    let path: String
    let sizeMB: String
}

struct DeployResponse: Encodable {
    let success: Bool
    let step: String          // "build" | "copy" | "codesign" | "done"
    let error: String?
    let message: String?
}

struct BackgroundJobSummary: Encodable {
    let pending: Int
    let running: Int
    let completed: Int
    let failed: Int
}

struct ActivityItem: Encodable {
    let id: String
    let type: String        // worker_completed | email_replied | scheduled_job_run | calendar_event_fired | supervisor_alert | background_thinking_output
    let title: String
    let subtitle: String
    let timestamp: Int64    // epoch ms
    let icon: String        // SF Symbol
    let collapsedCount: Int?
}

struct RecentActivityResponse: Encodable {
    let items: [ActivityItem]
    let generatedAt: Int64
}

struct DailyTokenTotal: Encodable {
    let date: String        // "YYYY-MM-DD" in the user's local zone
    let spendUSD: Double
    let totalTokens: Int64
}

struct TokenUsageTodaySummary: Encodable {
    let spendUSD: Double
    let totalTokens: Int64
}

struct TokenUsageTopConsumer: Encodable {
    let label: String
    let spendUSD: Double
}

struct TokenUsageAnomaly: Encodable {
    let flagged: Bool
    let ratio: Double?
}

struct TokenUsageResponse: Encodable {
    let today: TokenUsageTodaySummary
    let dailyTotals: [DailyTokenTotal]   // last 7 days, oldest → newest
    let topConsumer: TokenUsageTopConsumer?
    let anomaly: TokenUsageAnomaly
    let generatedAt: Int64
}
