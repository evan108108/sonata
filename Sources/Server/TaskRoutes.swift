import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct TaskRow: FetchableRecord, Codable {
    static let databaseTableName = "tasks"

    var id: String
    var title: String
    var description: String?
    var status: String
    var priority: String
    var prompt: String?
    var workingDir: String?
    var model: String?
    var maxTurns: Int?
    var project: String?
    var blockedBy: String
    var originalBlockedBy: String
    var parentTask: String?
    var source: String
    var sourceRef: String?
    var result: String?
    var outputFiles: String
    var tags: String
    var assignedTo: String?
    var dueAt: Int64?
    var startedAt: Int64?
    var completedAt: Int64?
    var retryCount: Int
    var maxRetries: Int?
    var lastError: String?
    var tools: String
    var metadata: String?
    var createdAt: Int64
    var updatedAt: Int64
}

// MARK: - Request Bodies

struct CreateTaskRequest: Decodable {
    let title: String
    let description: String?
    let status: String?
    let priority: String?
    let prompt: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let project: String?
    let blockedBy: [String]?
    let parentTask: String?
    let source: String
    let sourceRef: String?
    let tags: [String]?
    let assignedTo: String?
    let dueAt: Int64?
    let maxRetries: Int?
    let tools: [String]?
    let metadata: String?
}

struct PatchTaskRequest: Decodable {
    let id: String
    let title: String?
    let description: String?
    let status: String?
    let priority: String?
    let prompt: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let project: String?
    let blockedBy: [String]?
    let originalBlockedBy: [String]?
    let parentTask: String?
    let source: String?
    let sourceRef: String?
    let result: String?
    let outputFiles: [String]?
    let tags: [String]?
    let assignedTo: String?
    let dueAt: Int64?
    let startedAt: Int64?
    let completedAt: Int64?
    let retryCount: Int?
    let maxRetries: Int?
    let lastError: String?
    let tools: [String]?
    let metadata: String?
}

struct TaskFailRequest: Decodable {
    let lastError: String?
}

// MARK: - Response

struct TaskResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let title: String
    let description: String?
    let status: String
    let priority: String
    let prompt: String?
    let workingDir: String?
    let model: String?
    let maxTurns: Int?
    let project: String?
    let blockedBy: [String]
    let originalBlockedBy: [String]
    let parentTask: String?
    let source: String
    let sourceRef: String?
    let result: String?
    let outputFiles: [String]
    let tags: [String]
    let assignedTo: String?
    let dueAt: Int64?
    let startedAt: Int64?
    let completedAt: Int64?
    let retryCount: Int
    let maxRetries: Int?
    let lastError: String?
    let tools: [String]
    let metadata: String?
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(status, forKey: .status)
        try c.encode(priority, forKey: .priority)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(workingDir, forKey: .workingDir)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(maxTurns, forKey: .maxTurns)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(blockedBy, forKey: .blockedBy)
        try c.encode(originalBlockedBy, forKey: .originalBlockedBy)
        try c.encodeIfPresent(parentTask, forKey: .parentTask)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sourceRef, forKey: .sourceRef)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encode(outputFiles, forKey: .outputFiles)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(assignedTo, forKey: .assignedTo)
        try c.encodeIfPresent(dueAt, forKey: .dueAt)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encode(retryCount, forKey: .retryCount)
        try c.encodeIfPresent(maxRetries, forKey: .maxRetries)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encode(tools, forKey: .tools)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case title, description, status, priority
        case prompt, workingDir, model, maxTurns
        case project, blockedBy, originalBlockedBy, parentTask
        case source, sourceRef, result, outputFiles
        case tags, assignedTo, dueAt, startedAt, completedAt
        case retryCount, maxRetries, lastError
        case tools, metadata, createdAt, updatedAt
    }
}

struct TaskStatsResponse: Encodable {
    let pending: Int
    let active: Int
    let completed: Int
    let failed: Int
    let cancelled: Int
    let total: Int
}

struct AckResponse: Encodable {
    let acknowledged: Int
}

struct AttentionTaskItem: Encodable {
    let id: String
    let title: String
    let status: String          // "failed" or "pending" (with blockedBy non-empty)
    let lastError: String?
    let blockedBy: String?      // JSON array string, used by UI to compute blocker count
    let updatedAt: Int64
}

struct AttentionTaskListResponse: Encodable {
    let items: [AttentionTaskItem]
}
