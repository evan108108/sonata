import XCTest
import GRDB
import HTTPTypes
@testable import Sonata

/// Regression tests for entity identity — the rule that decides which row a
/// name means, and the two write doors that used to disagree about it.
///
/// The bug these pin, observed live 2026-08-13:
///   * mem_store's inline annotation matched (name, type) and INSERTed a fork
///     on a type mismatch, returning success. The fork then STOLE the relation
///     that belonged on the original, because relations resolve by name against
///     the just-upserted set first.
///   * mem_entity_upsert matched NAME ALONE and ignored its own `type`, so it
///     could never address that fork — it resolved the name to whichever row
///     came back first and overwrote it. It overwrote the canonical
///     `Sona`/person row (1035 edges) and `score-hybrid`/code_component this way.
///
/// Both are silent-overwrite bugs, so every test here asserts on WHICH ROW was
/// written, not merely that the call succeeded. `success: true` was never the
/// missing signal — the id was.
final class EntityIdentityTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    /// Insert an entity with `edges` dangling relations so edge-count ranking
    /// has something to rank. Returns the entity id.
    @discardableResult
    private func insertEntity(
        _ pool: DatabasePool,
        id: String,
        name: String,
        type: String,
        description: String = "",
        edges: Int = 0,
        createdAt: Int64 = 1_000
    ) throws -> String {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO entities (id, name, type, description, attributes, referenceCount, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, NULL, 0, ?, ?)
                """,
                arguments: [id, name, type, description, createdAt, createdAt]
            )
            for i in 0..<edges {
                try db.execute(
                    sql: """
                    INSERT INTO relations (id, sourceId, sourceType, targetId, targetType, relation, createdAt)
                    VALUES (?, ?, 'memory', ?, 'entity', 'about', ?)
                    """,
                    arguments: ["\(id)-edge-\(i)", "mem-\(id)-\(i)", id, createdAt]
                )
            }
        }
        return id
    }

    private func description(_ pool: DatabasePool, id: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT description FROM entities WHERE id = ?", arguments: [id])
        }
    }

    private func type(_ pool: DatabasePool, id: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT type FROM entities WHERE id = ?", arguments: [id])
        }
    }

    private func entityCount(_ pool: DatabasePool, name: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entities WHERE LOWER(name) = LOWER(?)", arguments: [name]) ?? 0
        }
    }

    private func json(_ value: any Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(EntityIdentityEncodableShim(value: value))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - The shared rule

    func testCandidatesRankMostConnectedFirstAndMatchCaseInsensitively() throws {
        let pool = try makePool()
        try insertEntity(pool, id: "stub", name: "Sona", type: "agent", edges: 2)
        try insertEntity(pool, id: "hub", name: "sona", type: "person", edges: 9)

        let candidates = try pool.read { db in try entityCandidates(db, name: "SONA") }
        XCTAssertEqual(candidates.map(\.id), ["hub", "stub"],
            "a forked name must resolve most-connected-first, and matching must ignore case — mem_entity_upsert's case-SENSITIVE `WHERE name = ?` is how Evenflow/tool and evenflow/tool came to coexist")
    }

    func testCandidateOrderingIsTotalSoTwoCallersAgree() throws {
        let pool = try makePool()
        try insertEntity(pool, id: "newer", name: "Tie", type: "b", edges: 3, createdAt: 5_000)
        try insertEntity(pool, id: "older", name: "Tie", type: "a", edges: 3, createdAt: 2_000)

        let first = try pool.read { db in try entityCandidates(db, name: "Tie") }
        let second = try pool.read { db in try entityCandidates(db, name: "Tie") }
        XCTAssertEqual(first.map(\.id), ["older", "newer"],
            "equal edge counts must break by createdAt ASC — the old `LIMIT 1` with no ORDER BY let SQLite decide, so the same name could resolve to the fork one call and the hub the next")
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testResolvePicksTheTypeMatchEvenWhenItIsTheLessConnectedRow() throws {
        let pool = try makePool()
        try insertEntity(pool, id: "hub", name: "Sona", type: "person", edges: 9)
        try insertEntity(pool, id: "stub", name: "Sona", type: "agent", edges: 1)

        let resolution = try pool.read { db in try resolveEntity(db, name: "Sona", type: "agent") }
        guard case .matched(let target, let siblings) = resolution else {
            return XCTFail("expected .matched, got \(resolution)")
        }
        XCTAssertEqual(target.id, "stub",
            "the caller named type=agent — they must reach the agent row, not the more-connected person hub. Resolving this to the hub is the 2026-08-13 overwrite.")
        XCTAssertEqual(siblings.map(\.id), ["hub"], "the other same-name rows must be reported, not hidden")
    }

    func testResolveReportsTypeMismatchRatherThanPickingARow() throws {
        let pool = try makePool()
        try insertEntity(pool, id: "product", name: "Sonata", type: "product", edges: 54)
        try insertEntity(pool, id: "project", name: "Sonata", type: "project", edges: 32)

        let resolution = try pool.read { db in try resolveEntity(db, name: "Sonata", type: "tool") }
        guard case .typeMismatch(let candidates) = resolution else {
            return XCTFail("a name that exists only under other types must be .typeMismatch, got \(resolution)")
        }
        XCTAssertEqual(candidates.map(\.id), ["product", "project"])
    }

    func testResolveByNamePrefersTheHubOverTheStub() throws {
        let pool = try makePool()
        try insertEntity(pool, id: "stub", name: "score-hybrid", type: "component", edges: 2)
        try insertEntity(pool, id: "hub", name: "score-hybrid", type: "code_component", edges: 8)

        let resolved = try pool.read { db in try resolveEntityByName(db, name: "score-hybrid") }
        XCTAssertEqual(resolved?.id, "hub",
            "a bare name (relation targets, by-name lookup) must land on the row the graph actually uses — an edge pointed at the stub is an edge lost")
    }

    // MARK: - mem_entity_upsert

    private var upsert: SonataAction {
        entityActions.first { $0.name == "mem_entity_upsert" }!
    }

    func testUpsertReachesTheForkTheCallerNamedNotTheHub() async throws {
        let pool = try makePool()
        try insertEntity(pool, id: "hub", name: "Sona", type: "person", description: "the canonical hub", edges: 9)
        try insertEntity(pool, id: "stub", name: "Sona", type: "agent", description: "", edges: 1)

        let response = try await upsert.handler(ActionContext(
            params: ActionParams(["name": "Sona", "type": "agent", "description": "the agent fork"]),
            dbPool: pool
        ))
        let body = try json(response)

        XCTAssertEqual(body["id"] as? String, "stub",
            "upsert(name:Sona, type:agent) must write the agent row. Returning the hub's id here IS the bug: it overwrote a 1035-edge canonical row on 2026-08-13.")
        XCTAssertEqual(try description(pool, id: "hub"), "the canonical hub",
            "the row the caller did not name must be untouched")
        XCTAssertEqual(try description(pool, id: "stub"), "the agent fork")
        XCTAssertEqual(body["matchedBy"] as? String, "name+type")
        XCTAssertEqual(body["created"] as? Bool, false)
        XCTAssertNotNil(body["warnings"],
            "a forked name must be reported even when the type resolved it unambiguously")
    }

    func testUpsertRefusesToOverwriteARowOfADifferentType() async throws {
        let pool = try makePool()
        try insertEntity(pool, id: "product", name: "Sonata", type: "product", description: "the real description", edges: 54)

        do {
            _ = try await upsert.handler(ActionContext(
                params: ActionParams(["name": "Sonata", "type": "tool", "description": "clobber"]),
                dbPool: pool
            ))
            XCTFail("upsert must not silently write a row whose type the caller did not name")
        } catch let error as ActionError {
            guard case .custom(let message, let status) = error else {
                return XCTFail("expected .custom conflict, got \(error)")
            }
            XCTAssertEqual(status, .conflict)
            XCTAssertTrue(message.contains("product"),
                "the error must name the conflicting rows so the caller can pass an id; got: \(message)")
        }

        XCTAssertEqual(try description(pool, id: "product"), "the real description",
            "the refused call must leave the row untouched")
        XCTAssertEqual(try type(pool, id: "product"), "product",
            "the old code also flipped `type` on overwrite")
        XCTAssertEqual(try entityCount(pool, name: "Sonata"), 1,
            "refusing must not fork either — erroring is the point")
    }

    func testUpsertByIdAddressesAForkedRowDirectly() async throws {
        let pool = try makePool()
        try insertEntity(pool, id: "hub", name: "Sona", type: "person", description: "hub", edges: 9)
        try insertEntity(pool, id: "stub", name: "Sona", type: "agent", description: "", edges: 1)

        let response = try await upsert.handler(ActionContext(
            params: ActionParams(["id": "stub", "name": "Sona", "type": "persona", "description": "retyped by id"]),
            dbPool: pool
        ))
        let body = try json(response)

        XCTAssertEqual(body["id"] as? String, "stub")
        XCTAssertEqual(body["matchedBy"] as? String, "id")
        XCTAssertEqual(try description(pool, id: "stub"), "retyped by id")
        XCTAssertEqual(try type(pool, id: "stub"), "persona",
            "`id` is the escape hatch, and the only way to change an entity's type")
        XCTAssertEqual(try description(pool, id: "hub"), "hub")
    }

    func testUpsertByUnknownIdIsNotFoundRatherThanASilentInsert() async throws {
        let pool = try makePool()
        do {
            _ = try await upsert.handler(ActionContext(
                params: ActionParams(["id": "ghost", "name": "X", "type": "t", "description": "d"]),
                dbPool: pool
            ))
            XCTFail("an id that matches nothing must not fall through to a create")
        } catch let error as ActionError {
            guard case .notFound = error else { return XCTFail("expected .notFound, got \(error)") }
        }
        XCTAssertEqual(try entityCount(pool, name: "X"), 0)
    }

    func testUpsertCreatesWhenTheNameIsAbsent() async throws {
        let pool = try makePool()
        let response = try await upsert.handler(ActionContext(
            params: ActionParams(["name": "Brand New", "type": "concept", "description": "d"]),
            dbPool: pool
        ))
        let body = try json(response)
        XCTAssertEqual(body["created"] as? Bool, true)
        XCTAssertEqual(body["matchedBy"] as? String, "created")
        XCTAssertEqual(try entityCount(pool, name: "Brand New"), 1)
    }

    func testUpsertMatchesCaseInsensitivelyAndKeepsTheStoredSpelling() async throws {
        let pool = try makePool()
        try insertEntity(pool, id: "canon", name: "evenflow", type: "tool", description: "old", edges: 374)

        let response = try await upsert.handler(ActionContext(
            params: ActionParams(["name": "Evenflow", "type": "tool", "description": "new"]),
            dbPool: pool
        ))
        let body = try json(response)

        XCTAssertEqual(body["id"] as? String, "canon")
        XCTAssertEqual(try entityCount(pool, name: "evenflow"), 1,
            "a case-variant must not become a second row — that is exactly how Evenflow/tool and evenflow/tool split in Feb 2026")
        let storedName = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM entities WHERE id = 'canon'")
        }
        XCTAssertEqual(storedName, "evenflow",
            "matching on case must not silently rename the stored row to the caller's casing")
    }

    // MARK: - mem_store inline annotation (the fork guard)

    private var store: SonataAction {
        memoryActions.first { $0.name == "mem_store" }!
    }

    /// l0/l1 are supplied so the handler skips Pith generation (which would
    /// reach for the local llama-server and make this test network-dependent).
    private func storeParams(entities: String, relations: String) -> ActionParams {
        ActionParams([
            "content": "test memory",
            "type": "learning",
            "l0": "l0",
            "l1": "l1",
            "entities": entities,
            "relations": relations,
        ])
    }

    private func relationTargets(_ pool: DatabasePool, memoryId: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT targetId FROM relations WHERE sourceId = ? AND targetType = 'entity' ORDER BY targetId",
                arguments: [memoryId]
            )
        }
    }

    func testAnnotationWithAWrongTypeDoesNotForkAndSaysSo() async throws {
        let pool = try makePool()
        try insertEntity(pool, id: "hub", name: "Sona", type: "person", description: "the canonical hub", edges: 9)

        let response = try await store.handler(ActionContext(
            params: storeParams(
                entities: #"[{"name":"Sona","type":"agent","description":"I am an agent"}]"#,
                relations: #"[{"entity":"Sona","relation":"about"}]"#
            ),
            dbPool: pool
        ))
        let body = try json(response)

        XCTAssertEqual(try entityCount(pool, name: "Sona"), 1,
            "a guessed type must not be able to split a hub — this is the 2026-07-22 Sona/agent fork")
        XCTAssertEqual(try relationTargets(pool, memoryId: body["id"] as! String), ["hub"],
            "the edge must land on the existing row; under the old code the fresh fork stole it")
        XCTAssertEqual(try description(pool, id: "hub"), "the canonical hub",
            "annotation must never overwrite an existing description")

        let warnings = body["warnings"] as? [String] ?? []
        guard let warning = warnings.first else {
            return XCTFail("the caller must be told their annotation went somewhere else; got \(body)")
        }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warning.contains("Sona/person"),
            "the warning must name the row that was actually written; got: \(warning)")
    }

    func testAnnotationEdgeLandsOnTheHubWhenTheNameIsAlreadyForked() async throws {
        let pool = try makePool()
        try insertEntity(pool, id: "hub", name: "score-hybrid", type: "code_component", edges: 8)
        try insertEntity(pool, id: "stub", name: "score-hybrid", type: "component", edges: 2)

        let response = try await store.handler(ActionContext(
            params: storeParams(
                entities: #"[{"name":"score-hybrid","type":"module"}]"#,
                relations: #"[{"entity":"score-hybrid","relation":"about"}]"#
            ),
            dbPool: pool
        ))
        let body = try json(response)

        XCTAssertEqual(try entityCount(pool, name: "score-hybrid"), 2, "no third row")
        XCTAssertEqual(try relationTargets(pool, memoryId: body["id"] as! String), ["hub"])
    }

    func testAnnotationStillCreatesAndLinksAGenuinelyNewEntity() async throws {
        let pool = try makePool()

        let response = try await store.handler(ActionContext(
            params: storeParams(
                entities: #"[{"name":"Fresh Thing","type":"concept","description":"desc"}]"#,
                relations: #"[{"entity":"Fresh Thing","relation":"about"}]"#
            ),
            dbPool: pool
        ))
        let body = try json(response)

        XCTAssertEqual(try entityCount(pool, name: "Fresh Thing"), 1)
        XCTAssertEqual(try relationTargets(pool, memoryId: body["id"] as! String).count, 1)
        XCTAssertNil(body["warnings"],
            "the happy path must stay quiet — a warning on every store trains callers to ignore them")
    }

    func testAnnotationReusesAnExactTypeMatchWithoutWarning() async throws {
        let pool = try makePool()
        try insertEntity(pool, id: "hub", name: "Scout", type: "project", description: "kept", edges: 4)

        let response = try await store.handler(ActionContext(
            params: storeParams(
                entities: #"[{"name":"scout","type":"PROJECT","description":"ignored"}]"#,
                relations: #"[{"entity":"Scout","relation":"about"}]"#
            ),
            dbPool: pool
        ))
        let body = try json(response)

        XCTAssertEqual(try entityCount(pool, name: "Scout"), 1)
        XCTAssertEqual(try relationTargets(pool, memoryId: body["id"] as! String), ["hub"])
        XCTAssertEqual(try description(pool, id: "hub"), "kept")
        XCTAssertNil(body["warnings"])
    }
}

// Type-erased Encodable shim so XCTest can JSONEncode `any Encodable` results
// without a concrete type at the call site.
private struct EntityIdentityEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
