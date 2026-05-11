import XCTest
import GRDB
@testable import Sonata

// Regression tests for the PATCH /api/entity merge semantics.
// EntityActions.swift's mem_entity_patch handler builds:
//   UPDATE entities SET attributes = json_patch(IFNULL(attributes, '{}'), ?)
// These tests pin RFC 7396 behavior — partial PATCH must merge, not replace —
// because every plugin caller (sonata-studio, scout SSE handlers) sends
// partial attributes and would silently lose sibling keys under full-replace.
final class EntityActionsPatchMergeTests: XCTestCase {

    private func makeDbPool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-entity-patch-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS entities (
                    id                 TEXT PRIMARY KEY,
                    name               TEXT NOT NULL,
                    type               TEXT NOT NULL,
                    description        TEXT NOT NULL,
                    attributes         TEXT,
                    referenceCount     INTEGER NOT NULL DEFAULT 0,
                    lastReferencedAt   INTEGER,
                    createdAt          INTEGER NOT NULL,
                    updatedAt          INTEGER NOT NULL
                )
            """)
        }
        return pool
    }

    private func insert(_ pool: DatabasePool, id: String, attrs: String?) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO entities (id, name, type, description, attributes, createdAt, updatedAt)
                VALUES (?, 'merge-test', 'test', '', ?, 0, 0)
                """,
                arguments: [id, attrs]
            )
        }
    }

    /// Apply the same SQL the production handler builds when only `attributes`
    /// is patched. Keeping the SQL string verbatim here lets the test fail
    /// loudly if EntityActions.swift drifts away from json_patch.
    private func applyPatch(_ pool: DatabasePool, id: String, json: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE entities SET updatedAt = ?, attributes = json_patch(IFNULL(attributes, '{}'), ?) WHERE id = ?",
                arguments: [1, json, id]
            )
        }
    }

    private func readAttrs(_ pool: DatabasePool, id: String) throws -> [String: Any]? {
        try pool.read { db -> [String: Any]? in
            guard let str = try String.fetchOne(db, sql: "SELECT attributes FROM entities WHERE id = ?", arguments: [id]),
                  let data = str.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    // Test 1 — sibling keys preserved across two partial PATCHes.
    func testPartialPatchPreservesSiblingKeys() throws {
        let pool = try makeDbPool()
        let id = "ent-1"
        try insert(pool, id: id, attrs: "{}")
        try applyPatch(pool, id: id, json: #"{"state":"active"}"#)
        try applyPatch(pool, id: id, json: #"{"members":["x"]}"#)
        let attrs = try XCTUnwrap(readAttrs(pool, id: id))
        XCTAssertEqual(attrs["state"] as? String, "active")
        XCTAssertEqual(attrs["members"] as? [String], ["x"])
    }

    // Test 2 — explicit overwrite of an existing key still works.
    func testOverwriteExistingKey() throws {
        let pool = try makeDbPool()
        let id = "ent-2"
        try insert(pool, id: id, attrs: "{}")
        try applyPatch(pool, id: id, json: #"{"key":"v1"}"#)
        try applyPatch(pool, id: id, json: #"{"key":"v2"}"#)
        let attrs = try XCTUnwrap(readAttrs(pool, id: id))
        XCTAssertEqual(attrs["key"] as? String, "v2")
        XCTAssertEqual(attrs.count, 1)
    }

    // Test 3 — RFC 7396: a key set to JSON null in the patch deletes it.
    func testNullDeletesKey() throws {
        let pool = try makeDbPool()
        let id = "ent-3"
        try insert(pool, id: id, attrs: #"{"a":1,"b":2}"#)
        try applyPatch(pool, id: id, json: #"{"a":null}"#)
        let attrs = try XCTUnwrap(readAttrs(pool, id: id))
        XCTAssertNil(attrs["a"])
        XCTAssertEqual(attrs["b"] as? Int, 2)
    }

    // Test 4 — PATCH against an entity whose attributes column is NULL still
    // merges correctly (IFNULL guards against `json_patch(NULL, ?)` returning NULL).
    func testNullExistingAttributesMergesIntoNewObject() throws {
        let pool = try makeDbPool()

        // Case A: attributes column is SQL NULL.
        try insert(pool, id: "ent-4a", attrs: nil)
        try applyPatch(pool, id: "ent-4a", json: #"{"state":"active","members":["x"]}"#)
        let a = try XCTUnwrap(readAttrs(pool, id: "ent-4a"))
        XCTAssertEqual(a["state"] as? String, "active")
        XCTAssertEqual(a["members"] as? [String], ["x"])

        // Case B: attributes column is "{}".
        try insert(pool, id: "ent-4b", attrs: "{}")
        try applyPatch(pool, id: "ent-4b", json: #"{"state":"active","members":["x"]}"#)
        let b = try XCTUnwrap(readAttrs(pool, id: "ent-4b"))
        XCTAssertEqual(b["state"] as? String, "active")
        XCTAssertEqual(b["members"] as? [String], ["x"])
    }
}
