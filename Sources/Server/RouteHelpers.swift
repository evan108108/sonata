import Foundation
import Hummingbird
import HTTPTypes

// MARK: - Shared Response Types

struct HealthResponse: Encodable {
    let status = "ok"
    let system = "claude-memory"
    let version = "1.0.0"
}

struct StoreResponse: Encodable {
    let id: String
    let success = true
}

struct SuccessResponse: Encodable {
    let success = true
}

struct PatchResponse: Encodable {
    let id: String
    let success = true
}

struct TouchResponse: Encodable {
    let touched: Int
}

struct ErrorResponse: Encodable {
    let error: String
}

// MARK: - Shared Helpers

func parseTags(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else {
        return []
    }
    return arr
}

func encodeTags(_ tags: [String]) -> String {
    guard let data = try? JSONEncoder().encode(tags),
          let str = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return str
}

func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok
) -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("Access-Control-Allow-Origin")!] = "*"
    headers[HTTPField.Name("Access-Control-Allow-Headers")!] = "Content-Type"
    headers[HTTPField.Name("Access-Control-Allow-Methods")!] = "GET, POST, PUT, DELETE, OPTIONS"
    return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: .init(data: data))
    )
}

func errorResponse(_ message: String, status: HTTPResponse.Status = .badRequest) -> Response {
    jsonResponse(ErrorResponse(error: message), status: status)
}

func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

func newUUID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}
