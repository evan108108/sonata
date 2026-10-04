import XCTest
import GRDB
@testable import Sonata

// Idempotent writes must tell the caller WHICH outcome happened. Before this,
// mem_relation_create answered {id, success:true} whether it inserted a row or
// deduped onto an existing one, and email_mark_replied answered {success:true}
// whether the email was unread, already replied, or not there at all. On
// 2026-10-03 a KG-enrichment run reported 24 "missing" edges from a zsh
// word-split bug in its own pre-scan; every create "succeeded", and only a
// worker comparing returned ids noticed 12 already existed. A write response
// with no already-there state cannot tell a caller its premise was wrong.
// See curiosity 798d0f3a and daily-learnings 351fa1ef.
//
// Each test drives the real MCP tools/call path twice and asserts that the
// second answer reports the no-op.
final class IdempotentWriteResponseTests: XCTestCase {

    private func makeHarness() throws -> MCPTestHarness {
        let h = try MCPTestHarness.make()
        h.actionRegistry.register(relationActions)
        h.actionRegistry.register(entityActions)
        h.actionRegistry.register(emailActions)
        return h
    }

    /// tools/call → the handler's JSON body, decoded. Fails the test on isError.
    private func call(_ h: MCPTestHarness, _ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
        let raw = await h.handle(
            sessionKey: "test-interactive", role: .interactive,
            method: "tools/call", id: 1,
            params: ["name": tool, "arguments": args])
        let envelope = try XCTUnwrap(raw).data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = try XCTUnwrap(envelope?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(tool) errored: \(text)")
        let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return try XCTUnwrap(body, "\(tool) returned non-object JSON: \(text)")
    }

    private func upsertEntity(_ h: MCPTestHarness, name: String, description: String = "seed") async throws -> String {
        let body = try await call(h, "mem_entity_upsert", ["name": name, "type": "project", "description": description])
        return try XCTUnwrap(body["id"] as? String)
    }

    // MARK: - mem_relation_create

    func testRelationCreateReportsCreatedThenDeduped() async throws {
        let h = try makeHarness()
        defer { h.teardown() }
        let src = try await upsertEntity(h, name: "Idem Source")
        let tgt = try await upsertEntity(h, name: "Idem Target")
        let args: [String: Any] = [
            "sourceId": src, "sourceType": "entity",
            "targetId": tgt, "targetType": "entity",
            "relation": "related_to",
        ]

        let first = try await call(h, "mem_relation_create", args)
        XCTAssertEqual(first["success"] as? Bool, true)
        XCTAssertEqual(first["created"] as? Bool, true, "first create must report created:true; got \(first)")
        let firstId = try XCTUnwrap(first["id"] as? String)

        let second = try await call(h, "mem_relation_create", args)
        XCTAssertEqual(second["success"] as? Bool, true, "dedup is still a success, not an error")
        XCTAssertEqual(second["created"] as? Bool, false, "dedup must report created:false; got \(second)")
        XCTAssertEqual(second["id"] as? String, firstId, "dedup must return the EXISTING relation id")

        let count = try await h.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relations WHERE sourceId = ?", arguments: [src]) ?? 0
        }
        XCTAssertEqual(count, 1, "dedup must not double-insert")
    }

    // MARK: - mem_entity_upsert

    func testEntityUpsertReportsInsertedUnchangedUpdated() async throws {
        let h = try makeHarness()
        defer { h.teardown() }
        let args: [String: Any] = ["name": "Idem Entity", "type": "project", "description": "first"]

        let first = try await call(h, "mem_entity_upsert", args)
        XCTAssertEqual(first["action"] as? String, "inserted", "got \(first)")
        XCTAssertEqual(first["created"] as? Bool, true, "existing field keeps its meaning")
        let id = try XCTUnwrap(first["id"] as? String)

        let second = try await call(h, "mem_entity_upsert", args)
        XCTAssertEqual(second["action"] as? String, "unchanged", "identical re-upsert must report unchanged; got \(second)")
        XCTAssertEqual(second["created"] as? Bool, false)
        XCTAssertEqual(second["id"] as? String, id)

        var changed = args
        changed["description"] = "second"
        let third = try await call(h, "mem_entity_upsert", changed)
        XCTAssertEqual(third["action"] as? String, "updated", "a changed description must report updated; got \(third)")
        XCTAssertEqual(third["id"] as? String, id)
    }

    func testEntityUpsertAttributesParticipateInChangeDetection() async throws {
        let h = try makeHarness()
        defer { h.teardown() }
        var args: [String: Any] = ["name": "Idem Attrs", "type": "project", "description": "d", "attributes": ["k": "v1"]]
        _ = try await call(h, "mem_entity_upsert", args)

        // Omitted attributes keep the stored value (COALESCE), so that is a no-op too.
        let omitted = try await call(h, "mem_entity_upsert", ["name": "Idem Attrs", "type": "project", "description": "d"])
        XCTAssertEqual(omitted["action"] as? String, "unchanged", "got \(omitted)")

        args["attributes"] = ["k": "v2"]
        let changed = try await call(h, "mem_entity_upsert", args)
        XCTAssertEqual(changed["action"] as? String, "updated", "got \(changed)")
    }

    func testEntityUpsertByIdReportsUnchanged() async throws {
        let h = try makeHarness()
        defer { h.teardown() }
        let id = try await upsertEntity(h, name: "Idem ById", description: "same")

        let byId = try await call(h, "mem_entity_upsert", ["id": id, "name": "Idem ById", "type": "project", "description": "same"])
        XCTAssertEqual(byId["matchedBy"] as? String, "id")
        XCTAssertEqual(byId["action"] as? String, "unchanged", "got \(byId)")

        let renamed = try await call(h, "mem_entity_upsert", ["id": id, "name": "Idem ById Renamed", "type": "project", "description": "same"])
        XCTAssertEqual(renamed["action"] as? String, "updated", "a rename by id is a change; got \(renamed)")
    }

    // MARK: - email_mark_replied

    func testEmailMarkRepliedReportsAlreadyReplied() async throws {
        let h = try makeHarness()
        defer { h.teardown() }
        try await h.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO emails (id, messageId, threadId, fromAddr, toAddr, subject, body, status, receivedAt)
                VALUES ('em1', '<m1@test>', 't1', 'a@x', 'b@x', 's', 'b', 'unread', 1)
                """)
        }

        let first = try await call(h, "email_mark_replied", ["id": "em1"])
        XCTAssertEqual(first["success"] as? Bool, true)
        XCTAssertEqual(first["found"] as? Bool, true, "got \(first)")
        XCTAssertEqual(first["alreadyReplied"] as? Bool, false, "got \(first)")

        let second = try await call(h, "email_mark_replied", ["messageId": "<m1@test>"])
        XCTAssertEqual(second["found"] as? Bool, true, "got \(second)")
        XCTAssertEqual(second["alreadyReplied"] as? Bool, true, "second mark must report alreadyReplied:true; got \(second)")
    }

    func testEmailMarkRepliedReportsUnknownId() async throws {
        let h = try makeHarness()
        defer { h.teardown() }
        let body = try await call(h, "email_mark_replied", ["id": "never-existed"])
        XCTAssertEqual(body["found"] as? Bool, false, "an id matching no row must say so; got \(body)")
    }
}
