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

/// Marks a response whose top-level key order is part of its contract.
///
/// Alphabetized keys (`.sortedKeys`) are the right default: most payloads here
/// are dictionary-shaped, and Swift dictionary iteration order varies between
/// processes, so sorting is what makes output stable and diffable.
///
/// They are the wrong default for a response that can outgrow the point where
/// its consumer truncates. A byte prefix has no notion of signal — it keeps
/// whatever sorts first. That is how `mem_recall` came to lead every response
/// with `_timings` (underscore sorts ahead of letters) while `memories` sat 7th
/// and `legs`/`warnings` — the blocks that exist so a dead retrieval leg can
/// announce itself — fell past the cut, always, and most reliably on the large
/// responses where the answer matters most.
///
/// Note that simply dropping `.sortedKeys` does NOT give declaration order:
/// `JSONEncoder` accumulates keyed containers in a dictionary, so unsorted
/// output is hash-ordered and varies run to run. Ordering therefore has to be
/// imposed at serialization time, which is what `orderedJSONData` does.
///
/// Conforming types must not declare custom `CodingKeys` that rename fields:
/// ordering is derived from the property names via `Mirror`, so a renamed key
/// would emit under its Swift name here and its coding-key name elsewhere.
protocol OrderedJSONResponse: Encodable {}

extension OrderedJSONResponse {
    /// Top-level fields in declaration order — `Mirror` preserves the order
    /// properties are written in, which keeps the struct itself the single
    /// source of truth for the wire contract.
    ///
    /// `nil` optionals are dropped rather than emitted as `null`, matching
    /// `encodeIfPresent`, so an omitted block costs zero bytes.
    var orderedJSONFields: [(key: String, value: any Encodable)] {
        Mirror(reflecting: self).children.compactMap { child in
            guard let label = child.label,
                  let encodable = child.value as? any Encodable
            else { return nil }
            let mirror = Mirror(reflecting: child.value)
            if mirror.displayStyle == .optional && mirror.children.isEmpty { return nil }
            return (label, encodable)
        }
    }
}

/// Encode one value as a bare JSON fragment.
///
/// Wraps in a single-element array and strips the brackets: `JSONEncoder`
/// rejects some top-level scalars outright, and this sidesteps the question for
/// every value shape. Nested keys stay sorted so dictionary-shaped members
/// (`legs`, `_timings`) remain deterministic.
private func encodeJSONFragment(_ value: any Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let wrapped = try encoder.encode([AnyEncodable(value)])
    return Data(wrapped.dropFirst().dropLast())
}

/// Serialize an `OrderedJSONResponse`, emitting fields in declaration order.
///
/// Output is compact by design: whitespace is pure cost in the truncated views
/// this exists to serve.
func orderedJSONData(_ value: some OrderedJSONResponse) throws -> Data {
    var out = Data("{".utf8)
    for (index, field) in value.orderedJSONFields.enumerated() {
        if index > 0 { out.append(UInt8(ascii: ",")) }
        // Encode the key as a string so escaping is the encoder's problem.
        let keyData = try JSONEncoder().encode([field.key])
        out.append(Data(keyData.dropFirst().dropLast()))
        out.append(UInt8(ascii: ":"))
        out.append(try encodeJSONFragment(field.value))
    }
    out.append(UInt8(ascii: "}"))
    return out
}

/// Serialize any handler result, honoring the `OrderedJSONResponse` contract.
/// Unwraps `AnyEncodable`, which erases the conformance before either the HTTP
/// or the MCP path sees it.
func responseJSONData(for value: any Encodable, prettyPrinted: Bool = false) -> Data {
    let ordered = (value as? AnyEncodable)?.orderedResponse ?? (value as? any OrderedJSONResponse)
    if let ordered, let data = try? orderedJSONData(ordered) {
        return data
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
    return (try? encoder.encode(value)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
}

func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok
) -> Response {
    let data = responseJSONData(for: value)
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
