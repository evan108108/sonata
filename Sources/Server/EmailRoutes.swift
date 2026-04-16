import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct EmailRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "emails"

    var id: String
    var messageId: String
    var threadId: String
    var fromAddr: String
    var toAddr: String
    var subject: String
    var body: String
    var status: String
    var receivedAt: Int64
    var repliedAt: Int64?
}

// MARK: - Request Bodies

struct StoreEmailRequest: Decodable {
    let messageId: String
    let threadId: String
    let from: String
    let to: String
    let subject: String
    let body: String
    let status: String?
    let receivedAt: Int64?
}

struct MarkEmailRequest: Decodable {
    let id: String?
    let messageId: String?
}

// MARK: - Response Types

struct EmailResponse: Encodable {
    let _id: String
    let messageId: String
    let threadId: String
    let from: String
    let to: String
    let subject: String
    let body: String
    let status: String
    let receivedAt: Int64
    let repliedAt: Int64?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(messageId, forKey: .messageId)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(subject, forKey: .subject)
        try c.encode(body, forKey: .body)
        try c.encode(status, forKey: .status)
        try c.encode(receivedAt, forKey: .receivedAt)
        try c.encodeIfPresent(repliedAt, forKey: .repliedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, messageId, threadId
        case from, to, subject, body
        case status, receivedAt, repliedAt
    }
}

struct UnreadCountResponse: Encodable {
    let unread: Int
}
