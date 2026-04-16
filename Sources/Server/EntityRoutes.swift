import Foundation
import Hummingbird
import GRDB

// MARK: - Database Row

struct EntityRow: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "entities"

    var id: String
    var name: String
    var type: String
    var description: String
    var attributesJSON: String?
    var referenceCount: Int
    var lastReferencedAt: Int64?
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, type, description
        case attributesJSON = "attributes"
        case referenceCount, lastReferencedAt
        case createdAt, updatedAt
    }
}

// MARK: - Request Bodies

struct UpsertEntityRequest: Decodable {
    let name: String
    let type: String
    let description: String
    let attributes: AnyCodable?
}

struct PatchEntityRequest: Decodable {
    let id: String
    let name: String?
    let type: String?
    let description: String?
    let attributes: AnyCodable?
}

struct TouchEntityRequest: Decodable {
    let id: String?
    let name: String?
}

struct TouchEntityResponse: Encodable {
    let id: String?
    let success: Bool
}

// MARK: - AnyCodable helper (for arbitrary JSON attributes)

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
}

// MARK: - Response shapes

/// Wire representation — mirrors the Convex response shape (with _id and _creationTime).
struct EntityResponse: Encodable {
    let _id: String
    let _creationTime: Int64
    let name: String
    let type: String
    let description: String
    let attributes: String?  // raw JSON string or nil
    let referenceCount: Int
    let lastReferencedAt: Int64?
    let createdAt: Int64
    let updatedAt: Int64

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_id, forKey: ._id)
        try c.encode(_creationTime, forKey: ._creationTime)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(description, forKey: .description)
        // Encode attributes as raw JSON (object) rather than a string
        if let attrJSON = attributes,
           let attrData = attrJSON.data(using: .utf8),
           let attrObj = try? JSONSerialization.jsonObject(with: attrData) {
            // Re-encode the parsed JSON to get proper JSON output
            let rawData = try JSONSerialization.data(withJSONObject: attrObj)
            let rawJSON = String(data: rawData, encoding: .utf8) ?? "null"
            try c.encode(RawJSON(rawJSON), forKey: .attributes)
        } else {
            try c.encodeNil(forKey: .attributes)
        }
        try c.encode(referenceCount, forKey: .referenceCount)
        try c.encodeIfPresent(lastReferencedAt, forKey: .lastReferencedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case _id, _creationTime
        case name, type, description, attributes
        case referenceCount, lastReferencedAt
        case createdAt, updatedAt
    }
}

/// Wrapper to emit raw JSON without double-encoding
struct RawJSON: Encodable {
    let json: String
    init(_ json: String) { self.json = json }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // We need to write the raw JSON directly
        // Since JSONEncoder will double-encode a string, we use a custom approach
        try container.encode(json)
    }
}

// MARK: - Helpers

func entityRowToResponse(_ row: EntityRow) -> EntityResponse {
    EntityResponse(
        _id: row.id,
        _creationTime: row.createdAt,
        name: row.name,
        type: row.type,
        description: row.description,
        attributes: row.attributesJSON,
        referenceCount: row.referenceCount,
        lastReferencedAt: row.lastReferencedAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt
    )
}
