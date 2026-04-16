import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct ScheduledJobRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "scheduledJobs"

    var id: String
    var name: String
    var schedule: String
    var command: String
    var enabled: Bool
    var lastRunAt: Double?
    var lastResult: String?
    var lastError: String?
    var lastExitCode: Double?
    var nextRunAt: Double?
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, schedule, command, enabled
        case lastRunAt, lastResult, lastError, lastExitCode
        case nextRunAt, createdAt
    }
}

// MARK: - Request Bodies

struct UpsertScheduledJobRequest: Decodable {
    let name: String
    let schedule: String
    let command: String
    let enabled: Bool?
    let nextRunAt: Double?
}

struct MarkRunRequest: Decodable {
    let lastResult: String?
    let lastExitCode: Double?
    let lastError: String?
}

// MARK: - Response Types

struct ScheduledJobResponse: Encodable {
    let _id: String
    let name: String
    let schedule: String
    let command: String
    let enabled: Bool
    let lastRunAt: Double?
    let lastResult: String?
    let lastError: String?
    let lastExitCode: Double?
    let nextRunAt: Double?
    let createdAt: Double
}
