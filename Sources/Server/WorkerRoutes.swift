import Foundation
import Hummingbird
import GRDB

// MARK: - Database Rows

struct WorkerRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "workers"

    var id: String
    var workerId: String
    var sessionLabel: String
    var status: String
    var capabilities: String
    var lastHeartbeat: Int64
    var currentEventId: String?
    var registeredAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, workerId, sessionLabel, status, capabilities
        case lastHeartbeat, currentEventId, registeredAt
    }
}

struct WorkerEventRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "workerEvents"

    var id: String
    var type: String
    var payload: String
    var priority: Int
    var assignedTo: String?
    var status: String
    var result: String?
    var createdAt: Int64
    var assignedAt: Int64?
    var completedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, type, payload, priority, assignedTo, status
        case result, createdAt, assignedAt, completedAt
    }
}

// MARK: - Request Bodies

struct WorkerHeartbeatRequest: Decodable {
    let workerId: String
    let lastProgressAt: Int64?
}

struct RegisterWorkerRequest: Decodable {
    let workerId: String
    let sessionLabel: String
    let capabilities: [String]?
}

struct CompleteEventBody: Decodable {
    let eventId: String
    let workerId: String?
    let result: String?
}

struct FailEventBody: Decodable {
    let eventId: String
    let workerId: String?
    let error: String?
}

struct EnqueueEventRequest: Decodable {
    let type: String
    let payload: String
    let priority: Int?
}

// MARK: - Response Types

struct WorkerResponse: Encodable {
    let _id: String
    let workerId: String
    let sessionLabel: String
    let status: String
    let capabilities: [String]
    let lastHeartbeat: Int64
    let currentEventId: String?
    let registeredAt: Int64
}

struct WorkerEventResponse: Encodable {
    let _id: String
    let type: String
    let payload: String
    let priority: Int
    let assignedTo: String?
    let status: String
    let result: String?
    let createdAt: Int64
    let assignedAt: Int64?
    let completedAt: Int64?
}

struct WorkerStatusResponse: Encodable {
    let online: Int
    let busy: Int
    let pendingEvents: Int
}

struct PurgeResponse: Encodable {
    let purged: Int
    let success = true
}
