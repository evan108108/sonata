import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct CalendarEventRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "calendarEvents"

    var id: String
    var title: String
    var description: String?
    var prompt: String?
    var scheduledAt: Int64
    var recurrence: String?
    var lastRunAt: Int64?
    var lastRunStatus: String?
    var runCount: Int
    var enabled: Int  // SQLite INTEGER (0/1)
    var project: String?
    var workingDir: String?
    var model: String?
    var maxTurns: Int?
    var taskType: String
    var createdAt: Int64
    var updatedAt: Int64
}

// MARK: - Request Bodies

struct CreateCalendarEventRequest: Decodable {
    let title: String
    let description: String?
    let prompt: String?
    let scheduledAt: Int64
    let recurrence: String?
    let enabled: Bool?
    let project: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let taskType: String
}

struct ExecutedCalendarBody: Decodable {
    let status: String?
}

struct UpdateCalendarEventRequest: Decodable {
    let id: String
    let title: String?
    let description: String?
    let prompt: String?
    let scheduledAt: Int64?
    let recurrence: String?
    let enabled: Bool?
    let project: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let taskType: String?
}

// MARK: - Response Types

struct CalendarEventResponse: Encodable {
    let _id: String
    let title: String
    let description: String?
    let prompt: String?
    let scheduledAt: Int64
    let recurrence: String?
    let lastRunAt: Int64?
    let lastRunStatus: String?
    let runCount: Int
    let enabled: Bool
    let project: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let taskType: String
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encode(scheduledAt, forKey: .scheduledAt)
        try c.encodeIfPresent(recurrence, forKey: .recurrence)
        try c.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try c.encodeIfPresent(lastRunStatus, forKey: .lastRunStatus)
        try c.encode(runCount, forKey: .runCount)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(workingDir, forKey: .workingDir)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(maxTurns, forKey: .maxTurns)
        try c.encode(taskType, forKey: .taskType)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, title, description, prompt
        case scheduledAt, recurrence
        case lastRunAt, lastRunStatus, runCount
        case enabled, project, workingDir, model, maxTurns, taskType
        case createdAt, updatedAt
    }
}
