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
