import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct BackgroundJobRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "backgroundJobs"

    var id: String
    var name: String
    var status: String
    var prompt: String
    var model: String?
    var maxTurns: Int?
    var result: String?
    var error: String?
    var createdAt: Int64
    var startedAt: Int64?
    var completedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, status, prompt, model, maxTurns
        case result, error, createdAt, startedAt, completedAt
    }
}

// MARK: - Request Bodies

struct CreateBackgroundJobRequest: Decodable {
    let name: String
    let prompt: String
    let model: String?
    let maxTurns: Int?
}

struct CompleteJobRequest: Decodable {
    let result: String?
}

struct FailJobRequest: Decodable {
    let error: String?
}

// MARK: - Response Types

struct BackgroundJobResponse: Encodable {
    let _id: String
    let name: String
    let status: String
    let prompt: String
    let model: String?
    let maxTurns: Int?
    let result: String?
    let error: String?
    let createdAt: Int64
    let startedAt: Int64?
    let completedAt: Int64?
}

struct TimeoutResponse: Encodable {
    let timedOut: Int
    let success = true
}

struct CleanupResponse: Encodable {
    let deleted: Int
    let success = true
}
