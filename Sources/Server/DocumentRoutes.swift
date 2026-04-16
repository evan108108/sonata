import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct DocumentRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "documents"

    var id: String
    var title: String
    var path: String
    var content: String
    var summary: String?
    var docType: String
    var project: String?
    var tagsJSON: String
    var relatedEntitiesJSON: String?
    var relatedMemoriesJSON: String?
    var parentDoc: String?
    var source: String
    var status: String
    var createdAt: Int64
    var updatedAt: Int64
    var lastIndexedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, path, content, summary, docType, project
        case tagsJSON = "tags"
        case relatedEntitiesJSON = "relatedEntities"
        case relatedMemoriesJSON = "relatedMemories"
        case parentDoc, source, status, createdAt, updatedAt, lastIndexedAt
    }
}

// MARK: - Request Bodies

struct IndexDocumentRequest: Decodable {
    let title: String
    let path: String
    let content: String
    let summary: String?
    let docType: String
    let project: String?
    let tags: [String]?
    let relatedEntities: [String]?
    let relatedMemories: [String]?
    let parentDoc: String?
    let source: String
    let status: String?
}

struct PatchDocumentRequest: Decodable {
    let id: String
    let title: String?
    let path: String?
    let content: String?
    let summary: String?
    let docType: String?
    let project: String?
    let tags: [String]?
    let relatedEntities: [String]?
    let relatedMemories: [String]?
    let parentDoc: String?
    let source: String?
    let status: String?
}

// MARK: - Response

struct DocumentResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let title: String
    let path: String
    let content: String
    let summary: String?
    let docType: String
    let project: String?
    let tags: [String]
    let relatedEntities: [String]?
    let relatedMemories: [String]?
    let parentDoc: String?
    let source: String
    let status: String
    let createdAt: Int64
    let updatedAt: Int64
    let lastIndexedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(title, forKey: .title)
        try c.encode(path, forKey: .path)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(docType, forKey: .docType)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(relatedEntities, forKey: .relatedEntities)
        try c.encodeIfPresent(relatedMemories, forKey: .relatedMemories)
        try c.encodeIfPresent(parentDoc, forKey: .parentDoc)
        try c.encode(source, forKey: .source)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(lastIndexedAt, forKey: .lastIndexedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case title, path, content, summary, docType, project
        case tags, relatedEntities, relatedMemories, parentDoc
        case source, status, createdAt, updatedAt, lastIndexedAt
    }
}

struct DocStatRow: FetchableRecord, Decodable {
    let docType: String
    let status: String
    let count: Int
}

struct DocStatsEntry: Encodable {
    let type: String
    let status: String
    let count: Int
}
