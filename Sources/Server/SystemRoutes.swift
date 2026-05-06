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
    let unreadEmails: Int
    let emailsByStatus: [String: Int]  // breakdown by email status (unread/read/replied/error/...)
    let nextCalendarEvent: NextEventInfo?
    let workerCount: Int               // alive: not offline, fresh heartbeat
    let workersByStatus: [String: Int] // breakdown by effective status (idle/busy/starting/.../stale/offline)
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
