import Foundation
import GRDB
import Hummingbird
import HummingbirdCore

// MARK: - Parameter Types

enum ParamType: String, Codable {
    case string
    case number
    case integer
    case boolean
    case stringArray  // Comma-separated string → [String]
    case object       // Raw JSON object pass-through
}

enum ParamSource {
    case auto     // query for GET/DELETE, body for POST/PATCH
    case query    // Always from query string
    case body     // Always from request body
    case path     // From URL path parameter (e.g. :id)
}

struct ActionParam {
    let name: String
    let type: ParamType
    let required: Bool
    let description: String
    let defaultValue: (any Sendable)?
    let source: ParamSource

    init(
        _ name: String,
        _ type: ParamType,
        required: Bool = false,
        description: String = "",
        default defaultValue: (any Sendable)? = nil,
        source: ParamSource = .auto
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.defaultValue = defaultValue
        self.source = source
    }
}

// MARK: - Parameter Bag

struct ActionParams: @unchecked Sendable {
    private let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    func string(_ key: String) -> String? {
        values[key] as? String
    }

    func int(_ key: String) -> Int? {
        if let i = values[key] as? Int { return i }
        if let s = values[key] as? String { return Int(s) }
        if let d = values[key] as? Double { return Int(d) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let d = values[key] as? Double { return d }
        if let s = values[key] as? String { return Double(s) }
        if let i = values[key] as? Int { return Double(i) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = values[key] as? Bool { return b }
        if let s = values[key] as? String {
            return ["true", "1", "yes"].contains(s.lowercased())
        }
        return nil
    }

    func stringArray(_ key: String) -> [String]? {
        if let arr = values[key] as? [String] { return arr }
        if let arr = values[key] as? [Any] {
            return arr.compactMap { $0 as? String }
        }
        if let s = values[key] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            // Empty string → empty array (callers commonly use "" to clear).
            if trimmed.isEmpty { return [] }
            // JSON array form: "[]", "[\"a\",\"b\"]" — decode strictly.
            if trimmed.hasPrefix("[") {
                if let data = trimmed.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String].self, from: data) {
                    return decoded
                }
                // Looks like JSON but didn't parse — treat as empty rather than
                // accidentally storing the literal "[]" as a single element.
                return []
            }
            // Comma-separated fallback for non-JSON strings.
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    func object(_ key: String) -> [String: Any]? {
        values[key] as? [String: Any]
    }

    /// Require a non-empty string param or throw
    func require(_ key: String) throws -> String {
        guard let v = string(key), !v.isEmpty else {
            throw ActionError.missingParam(key)
        }
        return v
    }

    /// Require an integer param or throw
    func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else {
            throw ActionError.missingParam(key)
        }
        return v
    }

    /// Get all raw values (for passing through to SQL, etc.)
    var all: [String: Any] { values }
}

// MARK: - Action Context

struct ActionContext: @unchecked Sendable {
    let params: ActionParams
    let dbPool: DatabasePool
    let scheduler: SchedulerActor?
    let search: (any SearchService)?

    init(
        params: ActionParams,
        dbPool: DatabasePool,
        scheduler: SchedulerActor? = nil,
        search: (any SearchService)? = nil
    ) {
        self.params = params
        self.dbPool = dbPool
        self.scheduler = scheduler
        self.search = search
    }
}

// MARK: - Action Error

enum ActionError: Error, LocalizedError {
    case missingParam(String)
    case invalidParam(String, String)  // name, reason
    case notFound(String)
    case database(String)
    case custom(String, HTTPResponse.Status)

    var errorDescription: String? {
        switch self {
        case .missingParam(let name): return "Missing required parameter: \(name)"
        case .invalidParam(let name, let reason): return "Invalid parameter '\(name)': \(reason)"
        case .notFound(let what): return "Not found: \(what)"
        case .database(let msg): return "Database error: \(msg)"
        case .custom(let msg, _): return msg
        }
    }

    var httpStatus: HTTPResponse.Status {
        switch self {
        case .missingParam, .invalidParam: return .badRequest
        case .notFound: return .notFound
        case .database: return .internalServerError
        case .custom(_, let status): return status
        }
    }
}

// MARK: - HTTP Method

enum ActionMethod: String, Codable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - MCP Text Formatter

/// Optional function that converts the JSON-encodable result to a human-readable
/// string for MCP tool responses. If nil, the result is JSON-serialized.
typealias MCPFormatter = @Sendable (any Encodable) -> String

// MARK: - The Action

struct SonataAction: Sendable {
    let name: String               // MCP tool name: "memory_recent", "task_list"
    let description: String        // Human-readable description
    let group: String              // HTTP route prefix: "/api/memory"
    let path: String               // HTTP route suffix: "/recent"
    let method: ActionMethod       // HTTP method
    let params: [ActionParam]      // Parameter definitions
    let handler: @Sendable (ActionContext) async throws -> any Encodable
    let mcpFormatter: MCPFormatter?  // Optional MCP-specific text formatter
    let httpOnly: Bool             // If true, no MCP tool generated (internal endpoints)
    let mcpOnly: Bool              // If true, no HTTP route generated (composite tools)

    init(
        name: String,
        description: String,
        group: String,
        path: String,
        method: ActionMethod,
        params: [ActionParam],
        httpOnly: Bool = false,
        mcpOnly: Bool = false,
        formatter: MCPFormatter? = nil,
        handler: @escaping @Sendable (ActionContext) async throws -> any Encodable
    ) {
        self.name = name
        self.description = description
        self.group = group
        self.path = path
        self.method = method
        self.params = params
        self.handler = handler
        self.mcpFormatter = formatter
        self.httpOnly = httpOnly
        self.mcpOnly = mcpOnly
    }

    /// Full HTTP path: group + path
    var fullPath: String { group + path }

    /// Generate MCP tool JSON schema
    func mcpToolSchema() -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []

        for p in params {
            var prop: [String: Any] = ["description": p.description]
            switch p.type {
            case .string:      prop["type"] = "string"
            case .number:      prop["type"] = "number"
            case .integer:     prop["type"] = "integer"
            case .boolean:     prop["type"] = "boolean"
            case .stringArray:
                prop["type"] = "array"
                prop["items"] = ["type": "string"]
            case .object:      prop["type"] = "object"
            }
            properties[p.name] = prop
            if p.required { required.append(p.name) }
        }

        var schema: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: Any],
        ]
        return schema
    }
}
