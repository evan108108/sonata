import XCTest
import GRDB
@testable import Sonata

/// mem_fetch_full prefix fallback (2026-10-25). l0 scans and summaries show
/// 8-char ids, and passing one back used to return "not found" for a memory
/// that exists. A missing id of 8–31 lowercase hex chars now resolves when it
/// matches exactly one memory; 2+ matches stay missing and are named.
final class FetchFullPrefixTests: XCTestCase {

    private let idA = "aaaaaaaa11111111111111111111111a"
    private let idB = "aaaaaaaa22222222222222222222222b"
    private let idC = "cccccccc33333333333333333333333c"

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    /// Store through the real handler (l0/l1 supplied so Pith isn't called),
    /// then pin the id so prefixes are deterministic.
    private func store(_ pool: DatabasePool, id: String, content: String) async throws {
        let store = memoryActions.first { $0.name == "mem_store" }!
        let response = try await store.handler(ActionContext(params: ActionParams([
            "content": content, "type": "observation", "l0": content, "l1": content,
            "source": "tests", "importance": 3,
        ]), dbPool: pool))
        let generated = try json(response)["id"] as? String ?? ""
        try await pool.write { db in
            try db.execute(sql: "UPDATE memories SET id = ? WHERE id = ?", arguments: [id, generated])
        }
    }

    private func seed() async throws -> DatabasePool {
        let pool = try makePool()
        try await store(pool, id: idA, content: "memory A")
        try await store(pool, id: idB, content: "memory B")
        try await store(pool, id: idC, content: "memory C")
        return pool
    }

    private func fetch(_ pool: DatabasePool, _ ids: [String]) async throws -> [String: Any] {
        let action = recallActions.first { $0.name == "mem_fetch_full" }!
        let response = try await action.handler(ActionContext(params: ActionParams(["ids": ids]), dbPool: pool))
        return try json(response)
    }

    private func json(_ value: any Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(FetchFullEncodableShim(value: value))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func ids(_ response: [String: Any]) -> [String] {
        ((response["memories"] as? [[String: Any]]) ?? []).compactMap { $0["_id"] as? String }
    }

    func testExactIdsAreUnchanged() async throws {
        let pool = try await seed()
        let r = try await fetch(pool, [idA, idC])
        XCTAssertEqual(ids(r), [idA, idC])
        XCTAssertEqual(r["found"] as? Int, 2)
        XCTAssertNil(r["missing"])
        XCTAssertNil(r["warning"])
        XCTAssertNil(r["resolvedPrefixes"], "an exact hit is not a prefix resolution")
        XCTAssertNil(r["ambiguousPrefixes"])
    }

    func testUniquePrefixResolves() async throws {
        let pool = try await seed()
        let r = try await fetch(pool, [idA, "cccccccc"])
        XCTAssertEqual(ids(r), [idA, idC], "the resolved memory keeps its request position")
        XCTAssertEqual(r["found"] as? Int, 2)
        XCTAssertEqual(r["resolvedPrefixes"] as? [String: String], ["cccccccc": idC])
        XCTAssertNil(r["missing"])
        XCTAssertNil(r["warning"])
        XCTAssertNil(r["ambiguousPrefixes"])
    }

    func testAmbiguousPrefixStaysMissing() async throws {
        let pool = try await seed()
        let r = try await fetch(pool, ["aaaaaaaa"])
        XCTAssertEqual(ids(r), [])
        XCTAssertEqual(r["missing"] as? [String], ["aaaaaaaa"])
        XCTAssertEqual(Set((r["ambiguousPrefixes"] as? [String: [String]])?["aaaaaaaa"] ?? []), [idA, idB])
        XCTAssertNil(r["resolvedPrefixes"])
        XCTAssertEqual(r["warning"] as? String,
                       "1 of 1 ids not found. Check each id was copied from a tool output, not typed.")
    }

    func testShortOrNonHexIsNeverResolved() async throws {
        let pool = try await seed()
        let r = try await fetch(pool, ["ccccccc", "CCCCCCCC", "cccccccc%", "cccc_ccc"])
        XCTAssertEqual(ids(r), [], "7 chars, uppercase, and LIKE wildcards never resolve")
        XCTAssertEqual(r["missing"] as? [String], ["ccccccc", "CCCCCCCC", "cccccccc%", "cccc_ccc"])
        XCTAssertNil(r["resolvedPrefixes"])
        XCTAssertNil(r["ambiguousPrefixes"])
        XCTAssertEqual(r["warning"] as? String,
                       "4 of 4 ids not found. Check each id was copied from a tool output, not typed.")
    }

    func testPrefixLengthBounds() {
        XCTAssertFalse(fetchFullIsResolvablePrefix("abcdef0"))
        XCTAssertTrue(fetchFullIsResolvablePrefix("abcdef01"))
        XCTAssertTrue(fetchFullIsResolvablePrefix(String(repeating: "a", count: 31)))
        XCTAssertFalse(fetchFullIsResolvablePrefix(String(repeating: "a", count: 32)), "a 32-char miss is a wrong id")
        XCTAssertFalse(fetchFullIsResolvablePrefix("abcdefg1"))
    }
}

private struct FetchFullEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
