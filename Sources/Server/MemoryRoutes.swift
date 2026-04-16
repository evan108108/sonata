import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct MemoryRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "memories"

    var id: String
    var content: String
    var type: String
    var tagsJSON: String
    var source: String?
    var importance: Double
    var l0: String?
    var l1: String?
    var accessCount: Int?
    var lastAccessedAt: Int64?
    var status: String?
    var supersededBy: String?
    var revisionOf: String?
    var revisionNote: String?
    var validFrom: Int64?
    var validUntil: Int64?
    var project: String?
    var topic: String?
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, content, type
        case tagsJSON = "tags"
        case source, importance, l0, l1
        case accessCount, lastAccessedAt
        case status, supersededBy, revisionOf, revisionNote
        case validFrom, validUntil, project, topic
        case createdAt, updatedAt
    }
}

// MARK: - Request Bodies

struct StoreMemoryRequest: Decodable {
    let content: String
    let type: String
    let tags: [String]?
    let source: String?
    let importance: Double?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
    let createdAt: Int64?
}

struct PatchMemoryRequest: Decodable {
    let id: String
    let content: String?
    let type: String?
    let tags: [String]?
    let source: String?
    let importance: Double?
    let l0: String?
    let l1: String?
    let status: String?
    let supersededBy: String?
    let revisionOf: String?
    let revisionNote: String?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
}

struct TouchRequest: Decodable {
    let ids: [String]
}

struct ReviseMemoryRequest: Decodable {
    let originalId: String
    let content: String
    let type: String?
    let tags: [String]?
    let source: String?
    let importance: Double?
    let revisionNote: String?
    let project: String?
    let topic: String?
}

struct SupersedeRequest: Decodable {
    let oldId: String
    let newId: String
}

struct ArchiveRequest: Decodable {
    let id: String
}

// Response types are in RouteHelpers.swift

/// Wire representation — mirrors the Convex response shape exactly.
/// Optional fields are omitted when nil (via custom encoder).
struct MemoryResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let content: String
    let type: String
    let tags: [String]
    let source: String?
    let importance: Double
    let l0: String?
    let l1: String?
    let accessCount: Int?
    let lastAccessedAt: Int64?
    let status: String?
    let supersededBy: String?
    let revisionOf: String?
    let revisionNote: String?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(content, forKey: .content)
        try c.encode(type, forKey: .type)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(importance, forKey: .importance)
        try c.encodeIfPresent(l0, forKey: .l0)
        try c.encodeIfPresent(l1, forKey: .l1)
        try c.encodeIfPresent(accessCount, forKey: .accessCount)
        try c.encodeIfPresent(lastAccessedAt, forKey: .lastAccessedAt)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(supersededBy, forKey: .supersededBy)
        try c.encodeIfPresent(revisionOf, forKey: .revisionOf)
        try c.encodeIfPresent(revisionNote, forKey: .revisionNote)
        try c.encodeIfPresent(validFrom, forKey: .validFrom)
        try c.encodeIfPresent(validUntil, forKey: .validUntil)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(topic, forKey: .topic)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case content, type, tags, source, importance
        case l0, l1
        case accessCount, lastAccessedAt
        case status, supersededBy, revisionOf, revisionNote
        case validFrom, validUntil, project, topic
        case createdAt, updatedAt
    }
}

// Shared helpers (parseTags, encodeTags, jsonResponse, etc.) are in RouteHelpers.swift
