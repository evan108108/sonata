import XCTest
import GRDB
@testable import Sonata

// Emit-side regression coverage for mem_relation_create / mem_relation_delete.
// Before this landed, both handlers returned `{success:true}` shape for the
// bad-id case:
//   - create with a truncated targetId wrote a dangling edge, silently
//     killing structural recall on the anchor memory (see learnings
//     6d43323c 2026-07-19 and db6c0952 2026-07-28 — the exact same finding
//     re-derived three times before a code fix landed).
//   - delete with an unknown id returned success and deleted zero rows.
// The handlers now throw ActionError.notFound with a distinctive message
// (dangling_source / dangling_target / "relation '<id>' does not exist")
// so a mistyped id fails loud at emit time instead of surfacing later as
// a mystery gap.
final class RelationActionsDanglingTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-rel-dangling-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        try pool.write { db in
            // Minimal schemas — just enough for the endpoint-existence check
            // and the RelationRow dedup lookup. The production schema has more
            // columns; nothing here reads them.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memories (
                    id      TEXT PRIMARY KEY,
                    status  TEXT
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS entities (
                    id   TEXT PRIMARY KEY,
                    name TEXT NOT NULL DEFAULT ''
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS relations (
                    id          TEXT PRIMARY KEY,
                    sourceId    TEXT NOT NULL,
                    sourceType  TEXT NOT NULL,
                    targetId    TEXT NOT NULL,
                    targetType  TEXT NOT NULL,
                    relation    TEXT NOT NULL,
                    createdAt   INTEGER NOT NULL
                )
            """)
        }
        return pool
    }

    private func seedEntity(_ pool: DatabasePool, id: String) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO entities (id, name) VALUES (?, 'seed')", arguments: [id])
        }
    }

    private func seedMemory(_ pool: DatabasePool, id: String) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO memories (id, status) VALUES (?, 'active')", arguments: [id])
        }
    }

    private func relationCountForSource(_ pool: DatabasePool, sourceId: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM relations WHERE sourceId = ?",
                arguments: [sourceId]
            ) ?? 0
        }
    }

    private var create: SonataAction {
        relationActions.first { $0.name == "mem_relation_create" }!
    }

    private var deleteAction: SonataAction {
        relationActions.first { $0.name == "mem_relation_delete" }!
    }

    // MARK: - create

    func testCreateRefusesDanglingTarget() async throws {
        let pool = try makePool()
        let goodSource = "aaaaaaaabbbbccccdddd1111eeee2222" // 32-hex, seeded
        let truncatedTarget = "12345678" // the 8-char class the task named
        try seedEntity(pool, id: goodSource)

        let ctx = ActionContext(
            params: ActionParams([
                "sourceId": goodSource,
                "sourceType": "entity",
                "targetId": truncatedTarget,
                "targetType": "entity",
                "relation": "mentions",
            ]),
            dbPool: pool
        )

        do {
            _ = try await create.handler(ctx)
            XCTFail("dangling target should have thrown; a truncated 8-char id was silently accepted")
        } catch let err as ActionError {
            guard case .notFound(let msg) = err else {
                XCTFail("expected ActionError.notFound, got \(err)")
                return
            }
            XCTAssertTrue(msg.contains("dangling_target"),
                "error message should carry the dangling_target token so callers can grep; got: \(msg)")
            XCTAssertTrue(msg.contains(truncatedTarget),
                "error message should echo the offending id; got: \(msg)")
        }

        // And the DB stays clean — no partial write from the refused call.
        XCTAssertEqual(try relationCountForSource(pool, sourceId: goodSource), 0,
            "a refused create must not leave a dangling edge behind")
    }

    func testCreateRefusesDanglingSource() async throws {
        let pool = try makePool()
        let goodTarget = "aaaaaaaabbbbccccdddd1111eeee2222"
        try seedEntity(pool, id: goodTarget)

        let ctx = ActionContext(
            params: ActionParams([
                "sourceId": "deadbeef",
                "sourceType": "entity",
                "targetId": goodTarget,
                "targetType": "entity",
                "relation": "mentions",
            ]),
            dbPool: pool
        )

        do {
            _ = try await create.handler(ctx)
            XCTFail("dangling source should have thrown")
        } catch let err as ActionError {
            guard case .notFound(let msg) = err else {
                XCTFail("expected ActionError.notFound, got \(err)")
                return
            }
            XCTAssertTrue(msg.contains("dangling_source"), "got: \(msg)")
        }
    }

    func testCreateSucceedsForWellFormedEndpoints() async throws {
        let pool = try makePool()
        let src = "aaaaaaaabbbbccccdddd1111eeee2222"
        let tgt = "ffffffff9999888877776666555544443"
        try seedEntity(pool, id: src)
        try seedMemory(pool, id: tgt)

        let ctx = ActionContext(
            params: ActionParams([
                "sourceId": src,
                "sourceType": "entity",
                "targetId": tgt,
                "targetType": "memory",
                "relation": "about",
            ]),
            dbPool: pool
        )

        let response = try await create.handler(ctx)
        let data = try JSONEncoder().encode(EncodableRelShim(value: response))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["success"] as? Bool, true)
        XCTAssertNotNil(json?["id"] as? String)
        XCTAssertEqual(try relationCountForSource(pool, sourceId: src), 1)

        // Dedup still works — a second identical create returns the same id.
        let firstId = json?["id"] as? String
        let response2 = try await create.handler(ctx)
        let data2 = try JSONEncoder().encode(EncodableRelShim(value: response2))
        let json2 = try JSONSerialization.jsonObject(with: data2) as? [String: Any]
        XCTAssertEqual(json2?["id"] as? String, firstId, "dedup should return the existing relation id")
        XCTAssertEqual(try relationCountForSource(pool, sourceId: src), 1, "dedup must not double-insert")
    }

    // MARK: - create — full sourceType × targetType × dangling-shape matrix
    //
    // The task's acceptance criterion is that all four (sourceType,targetType)
    // combinations refuse dangling ids for both dangling shapes: (a) invalid
    // shape (prefix/truncated/non-hex) and (b) valid 32-hex shape but no row.
    // The tests above already cover entity→entity for both source and target;
    // the matrix below fills in the remaining three combinations and the
    // valid-shape-missing-row shape.

    private struct Combo {
        let sourceType: String
        let targetType: String
    }

    private static let comboMatrix: [Combo] = [
        Combo(sourceType: "entity", targetType: "entity"),
        Combo(sourceType: "entity", targetType: "memory"),
        Combo(sourceType: "memory", targetType: "entity"),
        Combo(sourceType: "memory", targetType: "memory"),
    ]

    private func seedEndpoint(_ pool: DatabasePool, type: String, id: String) throws {
        switch type {
        case "entity":
            try seedEntity(pool, id: id)
        case "memory":
            try seedMemory(pool, id: id)
        default:
            XCTFail("unknown endpoint type \(type)")
        }
    }

    // Invalid-shape: 8-char prefix, the exact shape the 2026-09-17 cron hit.
    // Runs the same check for every (sourceType, targetType) pair with a
    // valid seeded source and a dangling target.
    func testCreateRefusesDanglingTarget_invalidShape_allCombos() async throws {
        for combo in Self.comboMatrix {
            let pool = try makePool()
            let goodSource = "aaaaaaaabbbbccccdddd1111eeee2222"
            let danglingTarget = "12345678"
            try seedEndpoint(pool, type: combo.sourceType, id: goodSource)

            let ctx = ActionContext(
                params: ActionParams([
                    "sourceId": goodSource,
                    "sourceType": combo.sourceType,
                    "targetId": danglingTarget,
                    "targetType": combo.targetType,
                    "relation": "mentions",
                ]),
                dbPool: pool
            )

            do {
                _ = try await create.handler(ctx)
                XCTFail("(\(combo.sourceType)→\(combo.targetType), invalid-shape) should refuse dangling target")
            } catch let err as ActionError {
                guard case .notFound(let msg) = err else {
                    XCTFail("(\(combo.sourceType)→\(combo.targetType), invalid-shape) expected notFound, got \(err)")
                    continue
                }
                XCTAssertTrue(msg.contains("dangling_target"),
                    "(\(combo.sourceType)→\(combo.targetType), invalid-shape) missing dangling_target token; got: \(msg)")
            }
            XCTAssertEqual(try relationCountForSource(pool, sourceId: goodSource), 0,
                "(\(combo.sourceType)→\(combo.targetType), invalid-shape) refused create must leave no row")
        }
    }

    // Valid 32-hex shape but no matching row — the yesterday-deleted-endpoint
    // case the task acceptance calls out. Same matrix.
    func testCreateRefusesDanglingTarget_validShapeMissingRow_allCombos() async throws {
        for combo in Self.comboMatrix {
            let pool = try makePool()
            let goodSource = "aaaaaaaabbbbccccdddd1111eeee2222"
            // Well-formed 32-hex id that we never seed.
            let missingTarget = "ee2b4d126c2948bda00625af5e546703"
            try seedEndpoint(pool, type: combo.sourceType, id: goodSource)

            let ctx = ActionContext(
                params: ActionParams([
                    "sourceId": goodSource,
                    "sourceType": combo.sourceType,
                    "targetId": missingTarget,
                    "targetType": combo.targetType,
                    "relation": "mentions",
                ]),
                dbPool: pool
            )

            do {
                _ = try await create.handler(ctx)
                XCTFail("(\(combo.sourceType)→\(combo.targetType), 32-hex-missing) should refuse dangling target")
            } catch let err as ActionError {
                guard case .notFound(let msg) = err else {
                    XCTFail("(\(combo.sourceType)→\(combo.targetType), 32-hex-missing) expected notFound, got \(err)")
                    continue
                }
                XCTAssertTrue(msg.contains("dangling_target"),
                    "(\(combo.sourceType)→\(combo.targetType), 32-hex-missing) missing dangling_target token; got: \(msg)")
            }
            XCTAssertEqual(try relationCountForSource(pool, sourceId: goodSource), 0,
                "(\(combo.sourceType)→\(combo.targetType), 32-hex-missing) refused create must leave no row")
        }
    }

    // Symmetric: dangling source with a valid target, both shapes, all combos.
    func testCreateRefusesDanglingSource_bothShapes_allCombos() async throws {
        for combo in Self.comboMatrix {
            for danglingSource in ["12345678", "ee2b4d126c2948bda00625af5e546703"] {
                let pool = try makePool()
                let goodTarget = "ffffffff9999888877776666555544443"
                try seedEndpoint(pool, type: combo.targetType, id: goodTarget)

                let ctx = ActionContext(
                    params: ActionParams([
                        "sourceId": danglingSource,
                        "sourceType": combo.sourceType,
                        "targetId": goodTarget,
                        "targetType": combo.targetType,
                        "relation": "mentions",
                    ]),
                    dbPool: pool
                )

                do {
                    _ = try await create.handler(ctx)
                    XCTFail("(\(combo.sourceType)→\(combo.targetType), source='\(danglingSource)') should refuse")
                } catch let err as ActionError {
                    guard case .notFound(let msg) = err else {
                        XCTFail("(\(combo.sourceType)→\(combo.targetType), source='\(danglingSource)') expected notFound, got \(err)")
                        continue
                    }
                    XCTAssertTrue(msg.contains("dangling_source"),
                        "(\(combo.sourceType)→\(combo.targetType), source='\(danglingSource)') missing dangling_source token; got: \(msg)")
                }
            }
        }
    }

    // Happy path across every combo — a well-formed create still succeeds
    // when both endpoints resolve. Guards against a refusal check that
    // accidentally rejects legal writes.
    func testCreateSucceeds_allCombos() async throws {
        for combo in Self.comboMatrix {
            let pool = try makePool()
            let src = "aaaaaaaabbbbccccdddd1111eeee2222"
            let tgt = "ffffffff9999888877776666555544443"
            try seedEndpoint(pool, type: combo.sourceType, id: src)
            try seedEndpoint(pool, type: combo.targetType, id: tgt)

            let ctx = ActionContext(
                params: ActionParams([
                    "sourceId": src,
                    "sourceType": combo.sourceType,
                    "targetId": tgt,
                    "targetType": combo.targetType,
                    "relation": "about",
                ]),
                dbPool: pool
            )

            let response = try await create.handler(ctx)
            let data = try JSONEncoder().encode(EncodableRelShim(value: response))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(json?["success"] as? Bool, true,
                "(\(combo.sourceType)→\(combo.targetType)) happy path should succeed")
            XCTAssertEqual(try relationCountForSource(pool, sourceId: src), 1,
                "(\(combo.sourceType)→\(combo.targetType)) happy path should write exactly one row")
        }
    }

    // MARK: - delete

    func testDeleteUnknownIdReturnsNotFound() async throws {
        let pool = try makePool()
        let ctx = ActionContext(
            params: ActionParams(["id": "never-existed"]),
            dbPool: pool
        )
        do {
            _ = try await deleteAction.handler(ctx)
            XCTFail("delete of unknown id should have thrown")
        } catch let err as ActionError {
            guard case .notFound(let msg) = err else {
                XCTFail("expected ActionError.notFound, got \(err)")
                return
            }
            XCTAssertTrue(msg.contains("never-existed"), "got: \(msg)")
        }
    }

    func testDeleteExistingIdStillSucceeds() async throws {
        let pool = try makePool()
        let src = "aaaaaaaabbbbccccdddd1111eeee2222"
        let tgt = "ffffffff9999888877776666555544443"
        try seedEntity(pool, id: src)
        try seedMemory(pool, id: tgt)

        let ctx = ActionContext(
            params: ActionParams([
                "sourceId": src,
                "sourceType": "entity",
                "targetId": tgt,
                "targetType": "memory",
                "relation": "about",
            ]),
            dbPool: pool
        )
        let response = try await create.handler(ctx)
        let data = try JSONEncoder().encode(EncodableRelShim(value: response))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let relId = try XCTUnwrap(json?["id"] as? String)

        let delCtx = ActionContext(
            params: ActionParams(["id": relId]),
            dbPool: pool
        )
        _ = try await deleteAction.handler(delCtx)
        XCTAssertEqual(try relationCountForSource(pool, sourceId: src), 0)
    }
}

private struct EncodableRelShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
