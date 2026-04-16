import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct ContactRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "contacts"

    var id: String
    var name: String
    var email: String
    var type: String
    var role: String?
    var provider: String?
    var model: String?
    var systemPrompt: String?
    var notes: String?
    var lastContactAt: Int64?
    var messageCount: Int
    var createdAt: Int64
    var updatedAt: Int64
}

// MARK: - Request Bodies

struct UpsertContactRequest: Decodable {
    let name: String
    let email: String
    let type: String
    let role: String?
    let provider: String?
    let model: String?
    let systemPrompt: String?
    let notes: String?
}

// MARK: - Response

struct ContactResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let name: String
    let email: String
    let type: String
    let role: String?
    let provider: String?
    let model: String?
    let systemPrompt: String?
    let notes: String?
    let lastContactAt: Int64?
    let messageCount: Int
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(name, forKey: .name)
        try c.encode(email, forKey: .email)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(lastContactAt, forKey: .lastContactAt)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case name, email, type, role, provider, model
        case systemPrompt, notes, lastContactAt, messageCount
        case createdAt, updatedAt
    }
}
