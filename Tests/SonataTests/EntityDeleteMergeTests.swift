import XCTest
import GRDB
import HTTPTypes
@testable import Sonata

/// Regression tests for graph-safe entity removal.
///
/// The bug these pin, observed 2026-09-28: mem_entity_delete ran a bare
/// `DELETE FROM entities` and returned success. Deleting the duplicate
/// "Campbell" row left all 91 of its relations pointing at a deleted id. The
/// duplicate "Evan" row has 2,792, so the hand repair used that day can't scale.
///
/// Every test asserts on the relations table, not on the call's success flag:
/// `success: true` was exactly what the broken delete returned.
final class EntityDeleteMergeTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func action(_ name: String) -> SonataAction {
        entityActions.first { $0.name == name }!
    }

    private func entity(_ pool: DatabasePool, _ id: String, name: String, type: String = "person",
                        description: String = "", attributes: String? = nil, refs: Int = 0) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO entities (id, name, type, description, attributes, referenceCount, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, 1000, 1000)
                """,
                arguments: [id, name, type, description, attributes, refs]
            )
        }
    }

    private func edge(_ pool: DatabasePool, _ id: String, _ source: (String, String), _ relation: String, _ target: (String, String)) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO relations (id, sourceId, sourceType, targetId, targetType, relation, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, 1000)
                """,
                arguments: [id, source.0, source.1, target.0, target.1, relation]
            )
        }
    }

    private func edgesReferencing(_ pool: DatabasePool, _ id: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relations WHERE sourceId = ? OR targetId = ?", arguments: [id, id]) ?? 0
        }
    }

    private func exists(_ pool: DatabasePool, _ id: String) throws -> Bool {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entities WHERE id = ?", arguments: [id]) ?? 0 } > 0
    }

    private func edgeIds(_ pool: DatabasePool, touching id: String? = nil) throws -> [String] {
        try pool.read { db in
            guard let id else { return try String.fetchAll(db, sql: "SELECT id FROM relations ORDER BY id") }
            return try String.fetchAll(db, sql: "SELECT id FROM relations WHERE sourceId = ? OR targetId = ? ORDER BY id", arguments: [id, id])
        }
    }

    private func attributesAndRefs(_ pool: DatabasePool, _ id: String) throws -> ([String: Any], Int) {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT attributes, referenceCount FROM entities WHERE id = ?", arguments: [id])!
            let json = (row["attributes"] as String?) ?? "{}"
            let object = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
            return (object, row["referenceCount"])
        }
    }

    private func call(_ name: String, _ params: [String: Any], _ pool: DatabasePool) async throws -> [String: Any] {
        let response = try await action(name).handler(ActionContext(params: ActionParams(params), dbPool: pool))
        let data = try JSONEncoder().encode(EntityDeleteMergeEncodableShim(value: response))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// An entity with an out-edge to an entity, an in-edge from an entity, and in-edges from memories.
    private func seedConnected(_ pool: DatabasePool, id: String) throws {
        try entity(pool, id, name: "Campbell")
        try entity(pool, "org", name: "Enginable", type: "organization")
        try entity(pool, "peer", name: "Conrad Stanek")
        try edge(pool, "e-out", (id, "entity"), "part_of", ("org", "entity"))
        try edge(pool, "e-in", ("peer", "entity"), "works_with", (id, "entity"))
        try edge(pool, "m-1", ("mem-1", "memory"), "mentions", (id, "entity"))
        try edge(pool, "m-2", ("mem-2", "memory"), "decided_by", (id, "entity"))
    }

    // MARK: - delete

    func testDeleteOfAConnectedEntityIsRefusedAndWritesNothing() async throws {
        let pool = try makePool()
        try seedConnected(pool, id: "dup")

        do {
            _ = try await call("mem_entity_delete", ["id": "dup"], pool)
            XCTFail("deleting an entity that still has relations must be refused; returning success here IS the 2026-09-28 bug")
        } catch let error as ActionError {
            guard case .custom(let message, let status) = error else { return XCTFail("expected .custom conflict, got \(error)") }
            XCTAssertEqual(status, .conflict)
            XCTAssertTrue(message.contains("4 relation"), "the refusal must name the edge count; got: \(message)")
            XCTAssertTrue(message.contains("mem_entity_merge"), "the refusal must point at the merge path; got: \(message)")
        }
        XCTAssertTrue(try exists(pool, "dup"), "a refused delete must leave the row")
        XCTAssertEqual(try edgesReferencing(pool, "dup"), 4, "a refused delete must leave every edge")
    }

    func testCascadeDeletesEveryEdgeInBothDirectionsWithTheEntity() async throws {
        let pool = try makePool()
        try seedConnected(pool, id: "junk")

        let body = try await call("mem_entity_delete", ["id": "junk", "cascade": true], pool)

        XCTAssertEqual(body["relationsDeleted"] as? Int, 4)
        XCTAssertFalse(try exists(pool, "junk"))
        XCTAssertEqual(try edgesReferencing(pool, "junk"), 0, "no relation may reference the deleted id")
        XCTAssertTrue(try exists(pool, "org"), "cascade removes edges, never the entities at their other end")
        XCTAssertTrue(try exists(pool, "peer"))
    }

    func testDeleteOfAnEntityWithNoEdgesNeedsNoCascade() async throws {
        let pool = try makePool()
        try entity(pool, "lonely", name: "TestEntity", type: "concept")

        let body = try await call("mem_entity_delete", ["id": "lonely"], pool)

        XCTAssertEqual(body["relationsDeleted"] as? Int, 0)
        XCTAssertFalse(try exists(pool, "lonely"))
    }

    func testDeleteOfAnUnknownIdIsNotFoundRatherThanASilentSuccess() async throws {
        let pool = try makePool()
        do {
            _ = try await call("mem_entity_delete", ["id": "nope"], pool)
            XCTFail("deleting an id that does not exist used to return success")
        } catch let error as ActionError {
            guard case .notFound = error else { return XCTFail("expected .notFound, got \(error)") }
        }
    }

    // MARK: - merge

    func testMergeMovesEveryEdgeDropsDuplicatesAndSelfLoopsAndKeepsTheOldIdentity() async throws {
        let pool = try makePool()
        try entity(pool, "canon", name: "Campbell Hyers", description: "Enginable co-founder", attributes: #"{"role":"ceo"}"#, refs: 3)
        try entity(pool, "dup", name: "Campbell", description: "CEO. NOT volatile.", refs: 2)
        try entity(pool, "org", name: "Enginable", type: "organization")
        // Edges only the duplicate has: must move.
        try edge(pool, "mv-1", ("mem-1", "memory"), "mentions", ("dup", "entity"))
        try edge(pool, "mv-2", ("dup", "entity"), "works_with", ("org", "entity"))
        // Same edge on both rows: the duplicate's copy must be dropped, not doubled.
        try edge(pool, "keep", ("mem-2", "memory"), "mentions", ("canon", "entity"))
        try edge(pool, "dupe", ("mem-2", "memory"), "mentions", ("dup", "entity"))
        // Edge between the two rows: would become canon -> canon.
        try edge(pool, "loop", ("dup", "entity"), "related_to", ("canon", "entity"))

        let body = try await call("mem_entity_merge", ["fromId": "dup", "intoId": "canon"], pool)
        let plan = body["plan"] as? [String: Any] ?? [:]

        XCTAssertEqual(plan["moved"] as? Int, 2)
        XCTAssertEqual(plan["duplicatesDropped"] as? Int, 1)
        XCTAssertEqual(plan["selfLoopsDropped"] as? Int, 1)
        XCTAssertEqual(plan["aliasesAdded"] as? [String], ["Campbell"])

        XCTAssertFalse(try exists(pool, "dup"))
        XCTAssertEqual(try edgesReferencing(pool, "dup"), 0, "no relation may still reference the merged-away id")
        XCTAssertEqual(try edgeIds(pool, touching: "canon"), ["keep", "mv-1", "mv-2"], "moved edges land on canon; the duplicate and the self-loop are gone")

        let (attrs, refs) = try attributesAndRefs(pool, "canon")
        XCTAssertEqual(attrs["aliases"] as? [String], ["Campbell"])
        XCTAssertEqual(attrs["role"] as? String, "ceo", "existing attributes must survive the merge")
        let mergedFrom = attrs["mergedFrom"] as? [[String: Any]]
        XCTAssertEqual(mergedFrom?.first?["description"] as? String, "CEO. NOT volatile.",
            "the duplicate's description must be kept, not guessed away")
        XCTAssertEqual(refs, 5, "reference counts are summed")
    }

    func testMergeDryRunReportsThePlanAndWritesNothing() async throws {
        let pool = try makePool()
        try entity(pool, "canon", name: "Evan Frohlich")
        try entity(pool, "dup", name: "Evan")
        try edge(pool, "m-1", ("mem-1", "memory"), "mentions", ("dup", "entity"))

        let body = try await call("mem_entity_merge", ["fromId": "dup", "intoId": "canon", "dryRun": true], pool)

        XCTAssertEqual((body["plan"] as? [String: Any])?["moved"] as? Int, 1)
        XCTAssertTrue(try exists(pool, "dup"), "dryRun must not delete")
        XCTAssertEqual(try edgesReferencing(pool, "dup"), 1, "dryRun must not move edges")
    }

    func testMergeRejectsSameIdAndUnknownIds() async throws {
        let pool = try makePool()
        try entity(pool, "canon", name: "Evan Frohlich")
        do {
            _ = try await call("mem_entity_merge", ["fromId": "canon", "intoId": "canon"], pool)
            XCTFail("merging a row into itself must be rejected")
        } catch let error as ActionError {
            guard case .invalidParam = error else { return XCTFail("expected .invalidParam, got \(error)") }
        }
        do {
            _ = try await call("mem_entity_merge", ["fromId": "ghost", "intoId": "canon"], pool)
            XCTFail("merging an unknown id must be rejected")
        } catch let error as ActionError {
            guard case .notFound = error else { return XCTFail("expected .notFound, got \(error)") }
        }
        XCTAssertTrue(try exists(pool, "canon"))
    }

    // MARK: - one-off dangling check

    func testDanglingCheckCountsOnlyMissingEntityEndpointsAndDeletesOnlyWhenAsked() async throws {
        let pool = try makePool()
        try entity(pool, "alive", name: "Evan Frohlich")
        try edge(pool, "ok", ("mem-1", "memory"), "mentions", ("alive", "entity"))
        try edge(pool, "dangling-target", ("mem-2", "memory"), "mentions", ("deleted", "entity"))
        try edge(pool, "dangling-source", ("deleted", "entity"), "works_with", ("alive", "entity"))
        // A memory endpoint that doesn't exist is not this check's business.
        try edge(pool, "memory-missing", ("no-such-memory", "memory"), "about", ("alive", "entity"))

        let report = try await call("mem_relation_dangling", [:], pool)
        XCTAssertEqual(report["count"] as? Int, 2)
        XCTAssertEqual(report["deleted"] as? Int, 0, "report-only by default")
        XCTAssertEqual(try edgeIds(pool).count, 4)

        let cleaned = try await call("mem_relation_dangling", ["delete": true], pool)
        XCTAssertEqual(cleaned["deleted"] as? Int, 2)
        XCTAssertEqual(try edgeIds(pool), ["memory-missing", "ok"], "only the two entity-dangling edges are deleted")
    }
}

private struct EntityDeleteMergeEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
