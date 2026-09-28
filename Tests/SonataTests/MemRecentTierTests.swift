import XCTest
import GRDB
@testable import Sonata

/// mem_recent tier=l0 (2026-09-28). Two background crons overflowed the MCP
/// tool-output cap the same morning (compression, limit=100: ~85 KB; daily
/// learnings, limit=40: ~84 KB) because mem_recent could only return whole
/// bodies. tier=l0 returns a scan line per memory; the default stays the full
/// shape so existing callers are untouched.
final class MemRecentTierTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func action(_ name: String) -> SonataAction {
        memoryActions.first { $0.name == name }!
    }

    /// Store through the real handler; l0/l1 supplied so Pith isn't called.
    @discardableResult
    private func store(_ pool: DatabasePool, _ content: String, type: String, l0: String, createdAt: Int64) async throws -> String {
        let response = try await action("mem_store").handler(ActionContext(params: ActionParams([
            "content": content, "type": type, "l0": l0, "l1": "l1 of \(l0)",
            "tags": ["tier-test"], "source": "tests", "importance": 4, "createdAt": Int(createdAt),
        ]), dbPool: pool))
        return try json(response)["id"] as? String ?? ""
    }

    private func recent(_ pool: DatabasePool, _ params: [String: Any]) async throws -> [[String: Any]] {
        let response = try await action("mem_recent").handler(ActionContext(params: ActionParams(params), dbPool: pool))
        let data = try JSONEncoder().encode(MemRecentEncodableShim(value: response))
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private func json(_ value: any Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(MemRecentEncodableShim(value: value))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func seed(_ pool: DatabasePool) async throws -> (noL0: String, body: String) {
        let body = String(repeating: "A long reflection body that a scan should never carry. ", count: 40)
        try await store(pool, "first " + body, type: "learning", l0: "First abstract.", createdAt: 1_790_000_000_000)
        try await store(pool, "second " + body, type: "reflection", l0: "Second abstract.", createdAt: 1_790_000_001_000)
        let noL0 = try await store(pool, "third " + body, type: "learning", l0: "tmp", createdAt: 1_790_000_002_000)
        try await pool.write { db in try db.execute(sql: "UPDATE memories SET l0 = NULL WHERE id = ?", arguments: [noL0]) }
        return (noL0, "third " + body)
    }

    func testDefaultIsTheFullShapeUnchanged() async throws {
        let pool = try makePool()
        _ = try await seed(pool)
        let byDefault = try await recent(pool, ["limit": 10])
        let explicit = try await recent(pool, ["limit": 10, "tier": "full"])
        XCTAssertEqual(byDefault.count, 3)
        XCTAssertEqual(NSArray(array: byDefault), NSArray(array: explicit), "no tier and tier=full are the same response")
        for m in byDefault {
            XCTAssertNotNil(m["content"] as? String, "the default still returns bodies")
            XCTAssertNotNil(m["l1"], "the default still returns l1")
            XCTAssertNotNil(m["_creationTime"])
            XCTAssertNil(m["_tier"], "the full shape gained no new keys")
        }
    }

    func testL0OmitsBodiesAndCarriesTheScanFields() async throws {
        let pool = try makePool()
        let (noL0, body) = try await seed(pool)
        try await pool.write { db in
            try db.execute(sql: "UPDATE memories SET status = 'active', accessCount = 3 WHERE id = ?", arguments: [noL0])
        }
        let rows = try await recent(pool, ["limit": 10, "tier": "l0"])
        let allowed: Set<String> = ["_id", "createdAt", "type", "importance", "source", "tags", "status", "l0", "accessCount", "_tier"]
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0["l0"] as? String }.first, String(body.prefix(recentL0FallbackChars)),
                       "newest first; with no stored abstract, l0 is the head of the body")
        for m in rows {
            XCTAssertNil(m["content"], "tier=l0 never carries the body")
            XCTAssertNil(m["l1"])
            // Like the full shape, NULL optionals (status, accessCount) are omitted, never sent as null.
            XCTAssertTrue(Set(m.keys).isSubset(of: allowed), "unexpected keys: \(Set(m.keys).subtracting(allowed))")
            XCTAssertTrue(Set(m.keys).isSuperset(of: ["_id", "createdAt", "type", "importance", "tags", "l0", "_tier"]))
            XCTAssertEqual(m["_tier"] as? String, "l0")
            XCTAssertEqual(m["source"] as? String, "tests")
            XCTAssertEqual(m["tags"] as? [String], ["tier-test"])
        }
        XCTAssertEqual(rows[0]["_id"] as? String, noL0)
        XCTAssertEqual(Set(rows[0].keys), allowed, "status and accessCount come through when set")
        XCTAssertEqual(rows[0]["status"] as? String, "active")
        XCTAssertEqual(rows[0]["accessCount"] as? Int, 3)
        XCTAssertEqual(rows[1]["l0"] as? String, "Second abstract.")
    }

    func testL0KeepsTheFilters() async throws {
        let pool = try makePool()
        _ = try await seed(pool)
        let rows = try await recent(pool, ["limit": 10, "tier": "l0", "type": "reflection"])
        XCTAssertEqual(rows.map { $0["l0"] as? String }, ["Second abstract."])
    }

    func testL0IsAScanNotAPayload() async throws {
        let pool = try makePool()
        _ = try await seed(pool)
        let full = try JSONSerialization.data(withJSONObject: try await recent(pool, ["limit": 10]))
        let l0 = try JSONSerialization.data(withJSONObject: try await recent(pool, ["limit": 10, "tier": "l0"]))
        XCTAssertLessThan(l0.count * 5, full.count, "l0 is several times smaller (\(l0.count) vs \(full.count) bytes)")
    }

    func testUnknownTierIsRejected() async throws {
        let pool = try makePool()
        do {
            _ = try await recent(pool, ["tier": "summary"])
            XCTFail("an unknown tier must not silently fall back")
        } catch let error as ActionError {
            XCTAssertTrue(error.localizedDescription.contains("tier"))
        }
    }
}

private struct MemRecentEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
