import XCTest
import GRDB
@testable import Sonata

/// mem_recall packing (2026-09-30). The tier=l0 loop walked every ranked
/// candidate (often ~5000) with no `limit` cap, and costed each item from a slim
/// {_id,type,l0,importance} string while the emitted item also carries tags,
/// `_scoreComponents`, `_rankScore`, `_searchRank` and three timestamps (~4–5x
/// larger), so `tokenUsage.used` understated the payload and overran `budget`.
final class RecallPackingTests: XCTestCase {

    private static let topic = "Zephyrine"

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func action(_ name: String) -> SonataAction {
        (memoryActions + recallActions).first { $0.name == name }!
    }

    private func json(_ value: any Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(RecallPackingEncodableShim(value: value))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// `count` memories that all mention the topic AND carry an edge to the topic
    /// entity, so the ranked list outgrows the FTS `limit` via the entity leg.
    /// Long abstracts + many tags make each emitted l0 item large.
    private func seed(_ pool: DatabasePool, count: Int) async throws {
        let abstract = String(repeating: "A deliberately long abstract about \(Self.topic). ", count: 8)
        let tags = (1...12).map { "packing-tag-\($0)" }
        for i in 0..<count {
            _ = try await action("mem_store").handler(ActionContext(params: ActionParams([
                "content": "Memory \(i) about \(Self.topic).", "type": "observation",
                "l0": "\(i): \(abstract)", "l1": "l1 \(i)",
                "tags": tags, "source": "tests", "importance": 4,
                "createdAt": 1_790_000_000_000 + i * 1000,
                "entities": "[{\"name\":\"\(Self.topic)\",\"type\":\"project\"}]",
                "relations": "[{\"entity\":\"\(Self.topic)\",\"relation\":\"about\"}]",
            ]), dbPool: pool))
        }
    }

    private func recall(_ pool: DatabasePool, _ params: [String: Any]) async throws -> (memories: [[String: Any]], usage: [String: Any], memoriesTokens: Int) {
        var p = params
        p["topic"] = Self.topic
        p["wander"] = "false"
        let response = try await action("mem_recall").handler(ActionContext(params: ActionParams(p), dbPool: pool))
        let body = try json(response)
        let memories = body["memories"] as? [[String: Any]] ?? []
        // What the memories section actually costs, by the recall's own chars/4 rule,
        // measured on the response's own JSONEncoder bytes (JSONSerialization
        // re-encodes floats and slashes differently, so it would drift a few chars).
        let raw = String(decoding: try JSONEncoder().encode(RecallPackingEncodableShim(value: response)), as: UTF8.self)
        let array = try XCTUnwrap(Self.jsonArray(named: "memories", in: raw))
        return (memories, body["tokenUsage"] as? [String: Any] ?? [:], (array.count + 3) / 4)
    }

    /// The raw text inside the first `"name":[...]` array, bracket-matched
    /// (JSONEncoder doesn't promise key order, so the following key can't anchor it).
    private static func jsonArray(named name: String, in raw: String) -> Substring? {
        guard let open = raw.range(of: "\"\(name)\":[") else { return nil }
        var depth = 1, inString = false, escaped = false
        var i = open.upperBound
        while i < raw.endIndex {
            let c = raw[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "[" || c == "{" {
                depth += 1
            } else if c == "]" || c == "}" {
                depth -= 1
                if depth == 0 { return raw[open.upperBound..<i] }
            }
            i = raw.index(after: i)
        }
        return nil
    }

    func testL0NeverReturnsMoreThanLimit() async throws {
        let pool = try makePool()
        try await seed(pool, count: 12)
        let r = try await recall(pool, ["limit": 5, "tier": "l0"])
        let total = r.usage["memoriesTotal"] as? Int ?? 0
        XCTAssertGreaterThan(total, 5, "the ranked list must outgrow limit, or this test proves nothing")
        XCTAssertEqual(r.memories.count, 5)
        XCTAssertLessThanOrEqual(r.usage["used"] as? Int ?? .max, r.usage["budget"] as? Int ?? 0)
    }

    func testL0UsedStaysWithinBudgetAndCoversThePayload() async throws {
        let pool = try makePool()
        try await seed(pool, count: 40)
        let r = try await recall(pool, ["limit": 30, "budget": 2000, "tier": "l0"])
        let used = r.usage["used"] as? Int ?? .max
        XCTAssertLessThanOrEqual(used, 2000)
        XCTAssertLessThan(r.memories.count, r.usage["memoriesTotal"] as? Int ?? 0, "the budget, not the pool, bounded this")
        XCTAssertLessThanOrEqual(r.memoriesTokens, 2000, "the emitted memories themselves fit the budget")
        XCTAssertGreaterThanOrEqual(Double(used), Double(r.memoriesTokens) * 0.9,
                                    "used is costed from the emitted items, not a slim stand-in")
    }

    func testFullTierAlsoCapsAtLimit() async throws {
        let pool = try makePool()
        try await seed(pool, count: 12)
        let r = try await recall(pool, ["limit": 5, "tier": "full"])
        XCTAssertEqual(r.memories.count, 5)
        XCTAssertLessThanOrEqual(r.usage["used"] as? Int ?? .max, r.usage["budget"] as? Int ?? 0)
    }
}

private struct RecallPackingEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
