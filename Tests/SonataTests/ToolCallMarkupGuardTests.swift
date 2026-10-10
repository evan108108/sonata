import XCTest
import GRDB
@testable import Sonata

/// A model's malformed tool call can close a parameter with the wrong tag
/// (`</description>` instead of the parameter closer). The parser then reads
/// everything up to the next real closer as the parameter's value, so the
/// stored text ends in tool-call markup and any parameter after it is lost.
/// On 2026-10-10 a sweep of 1,129 entities found 6 like this (plus one more,
/// fixed on 10/09); both meetings had attributes = null because the JSON was
/// inside the leaked tail. These tests drive the real handlers against the
/// real migrator: a leak is rejected at every write door, and prose that
/// QUOTES the markup still stores.
final class ToolCallMarkupGuardTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func memoryAction(_ name: String) -> SonataAction { memoryActions.first { $0.name == name }! }
    private func entityAction(_ name: String) -> SonataAction { entityActions.first { $0.name == name }! }

    private func run(_ action: SonataAction, _ pool: DatabasePool, _ params: [String: Any]) async throws -> any Encodable {
        try await action.handler(ActionContext(params: ActionParams(params), dbPool: pool))
    }

    private func storeParams(_ content: String) -> [String: Any] {
        // l0/l1 supplied so Pith (local llama-server) is never called.
        ["content": content, "type": "learning", "l0": "abstract", "l1": "summary", "source": "tests"]
    }

    private func count(_ pool: DatabasePool, _ sql: String) async throws -> Int {
        try await pool.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    /// The rejection must be an invalid-param error that names the field, the
    /// fragment and its offset, so the caller knows what to strip and retry.
    private func assertRejected(
        _ body: () async throws -> Void, field: String, fragment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected the write to be rejected for leaked \(fragment)", file: file, line: line)
        } catch let ActionError.invalidParam(name, reason) {
            XCTAssertEqual(name, field, file: file, line: line)
            XCTAssertTrue(reason.contains(fragment), "reason must name the fragment; got: \(reason)", file: file, line: line)
            XCTAssertTrue(reason.contains("offset"), "reason must give the offset; got: \(reason)", file: file, line: line)
        } catch {
            XCTFail("expected ActionError.invalidParam, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Fixtures are the real rows

    /// Lengths from the pre-repair dump. A fixture that drifted from the real
    /// row would test a shape that never happened.
    func testFixturesAreTheSixRealLeakedRows() {
        let expected: [String: Int] = [
            "Stand up 2026-09-14": 1121, "Stand up 2026-08-18": 1323, "ADA-558": 519,
            "PR-573": 576, "Rationalization Detection": 2222, "structure-fitting": 1054,
        ]
        XCTAssertEqual(ToolCallMarkupLeakFixtures.leaked.count, 6)
        for (name, description) in ToolCallMarkupLeakFixtures.leaked {
            XCTAssertEqual(description.count, expected[name], "\(name) fixture length drifted")
        }
    }

    // MARK: - Detector

    func testEachRealLeakedShapeIsDetected() {
        for (name, description) in ToolCallMarkupLeakFixtures.leaked {
            XCTAssertNotNil(ToolCallMarkupGuard.findLeak(in: description), "\(name) must be detected as leaked")
        }
    }

    /// The meetings' `</description>` sits 234 and 242 characters from the
    /// end, outside the tail window. Only the "followed by <parameter name="
    /// rule reaches it, so the reported fragment must be that one, at the
    /// offset where the leak starts.
    func testMeetingLeakIsReportedAtTheClosingTagOffset() throws {
        let (_, description) = try XCTUnwrap(ToolCallMarkupLeakFixtures.leaked.first { $0.name == "Stand up 2026-09-14" })
        let leak = try XCTUnwrap(ToolCallMarkupGuard.findLeak(in: description))
        XCTAssertEqual(leak.fragment, "</description>")
        let expectedOffset = description.distance(
            from: description.startIndex,
            to: try XCTUnwrap(description.range(of: "</description>")).lowerBound)
        XCTAssertEqual(leak.offset, expectedOffset)
        XCTAssertGreaterThan(description.count - leak.offset, ToolCallMarkupGuard.tailWindow,
                             "fixture must exercise the structure rule, not the tail rule")
    }

    func testStructureRuleReachesALeakFarFromTheEnd() {
        let text = "Real description.</description>\n<parameter name=\"attributes\">"
            + "{\"notes\": \"" + String(repeating: "x", count: 600) + "\"}"
        XCTAssertEqual(ToolCallMarkupGuard.findLeak(in: text)?.fragment, "</description>")
    }

    func testLeadingInvokeIsDetected() {
        XCTAssertNotNil(ToolCallMarkupGuard.findLeak(in: "  <invoke name=\"mem_store\">" + String(repeating: "prose ", count: 100)))
    }

    func testCleanTextPasses() {
        XCTAssertNil(ToolCallMarkupGuard.findLeak(in: "A plain description of an entity. It mentions <b>html</b> and a < b."))
        XCTAssertNil(ToolCallMarkupGuard.findLeak(in: ""))
    }

    /// This task's own wording: the fragments are quoted mid-sentence with
    /// literal `\n` escapes between them, and the text goes on long after.
    func testMemoryQuotingTheMarkupMidSentencePasses() {
        XCTAssertNil(ToolCallMarkupGuard.findLeak(in: Self.quotingMemory))
    }

    /// Real memory tails from the 2026-10-10 memory sweep, a different
    /// parameter from the entity leaks: `</content>` swallowing tags/source,
    /// and bare-XML params (`<entities>`, `<relations>`) closed by `</invoke>`.
    func testContentLeakShapesFromTheMemorySweepAreDetected() {
        let tails = [
            // 9c3c779f: </content> then the swallowed tags parameter.
            #"""
            ...the correct response is the scheduler fix (tasks dd43481b / a4f5a1a7), NOT a sixth consolidation. Observation caps at limit=50 so the true observation count may be higher.</content>
            <parameter name="tags">["cron-log", "consolidation", "dual-dispatch", "recurrence-is-the-signal"]
            """#,
            // 7d889ccc: bare-XML parameters swallowed whole.
            #"""
            ...posts findings as issue comments rather than formal reviews (GitHub self-review block)."}]</entities>
            <relations>[{"entity":"prfix","relation":"about"},{"entity":"prStar","relation":"about"}]</relations>
            </invoke>
            """#,
            // 8a42b2ad: two swallowed parameters, the whole memory is 129 chars.
            #"""
            Cron: conceptualCollision ran.</content>
            <parameter name="tags">cron-log</parameter>
            <parameter name="source">background-thinking
            """#,
        ]
        for tail in tails {
            XCTAssertNotNil(ToolCallMarkupGuard.findLeak(in: String(repeating: "Body text. ", count: 60) + tail), tail)
        }
    }

    /// Memory 8304f340 (2026-10-09) describes the bug by quoting both
    /// fragments back to back, but loosely (no quotes on the name). It must
    /// still store; only a well-formed `<parameter name="x">` continues a call.
    func testProseQuotingAdjacentFragmentsLooselyPasses() {
        let text = #"""
        What the interrupted run had NOT finished: (1) the meeting entity was malformed, with null attributes and a leaked "</description><parameter name=attributes>" fragment in its description; patched, with source_transcript set to the new filename.
        """# + String(repeating: " Later prose that keeps the quote far from the end.", count: 10)
        XCTAssertNil(ToolCallMarkupGuard.findLeak(in: text))
    }

    // MARK: - Write doors

    func testCleanStorePasses() async throws {
        let pool = try makePool()
        _ = try await run(memoryAction("mem_store"), pool, storeParams("A clean learning with no markup in it."))
        let n = try await count(pool, "SELECT COUNT(*) FROM memories")
        XCTAssertEqual(n, 1)
    }

    func testQuotingMemoryStores() async throws {
        let pool = try makePool()
        _ = try await run(memoryAction("mem_store"), pool, storeParams(Self.quotingMemory))
        let n = try await count(pool, "SELECT COUNT(*) FROM memories")
        XCTAssertEqual(n, 1)
    }

    func testStoreRejectsEachLeakedShape() async throws {
        let pool = try makePool()
        for (_, description) in ToolCallMarkupLeakFixtures.leaked {
            await assertRejected({ _ = try await self.run(self.memoryAction("mem_store"), pool, self.storeParams(description)) },
                                 field: "content", fragment: "</")
        }
        let n = try await count(pool, "SELECT COUNT(*) FROM memories")
        XCTAssertEqual(n, 0, "no leaked row may be written")
    }

    /// The inline `entities` door used to be best-effort AFTER the memory
    /// insert. A leaked entity description must reject the whole call before
    /// anything is written, or the memory lands and the leak lands with it.
    func testStoreRejectsLeakedInlineEntityBeforeWritingTheMemory() async throws {
        let pool = try makePool()
        let (_, leaked) = ToolCallMarkupLeakFixtures.leaked[0]
        let entities = String(data: try JSONSerialization.data(withJSONObject: [
            ["name": "Stand up 2026-09-14", "type": "meeting", "description": leaked],
        ]), encoding: .utf8)!
        var params = storeParams("A clean memory body.")
        params["entities"] = entities
        await assertRejected({ _ = try await self.run(self.memoryAction("mem_store"), pool, params) },
                             field: "entities", fragment: "</description>")
        let memories = try await count(pool, "SELECT COUNT(*) FROM memories")
        let rows = try await count(pool, "SELECT COUNT(*) FROM entities")
        XCTAssertEqual(memories, 0)
        XCTAssertEqual(rows, 0)
    }

    func testEntityUpsertRejectsEachLeakedShape() async throws {
        let pool = try makePool()
        for (name, description) in ToolCallMarkupLeakFixtures.leaked {
            await assertRejected({
                _ = try await self.run(self.entityAction("mem_entity_upsert"), pool,
                                       ["name": name, "type": "concept", "description": description])
            }, field: "description", fragment: "</")
        }
        let n = try await count(pool, "SELECT COUNT(*) FROM entities")
        XCTAssertEqual(n, 0)
    }

    func testEntityUpsertCleanPasses() async throws {
        let pool = try makePool()
        _ = try await run(entityAction("mem_entity_upsert"), pool,
                          ["name": "Clean Entity", "type": "concept", "description": "Nothing to see."])
        let n = try await count(pool, "SELECT COUNT(*) FROM entities")
        XCTAssertEqual(n, 1)
    }

    func testEntityPatchRejectsLeakAndKeepsTheOldDescription() async throws {
        let pool = try makePool()
        let body = try await run(entityAction("mem_entity_upsert"), pool,
                                 ["name": "Patch Target", "type": "concept", "description": "original"])
        let id = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(AnyEncodable(body))) as? [String: Any])["id"] as! String
        let (_, leaked) = ToolCallMarkupLeakFixtures.leaked[2]  // ADA-558: "</description>\n</invoke>"
        await assertRejected({
            _ = try await self.run(self.entityAction("mem_entity_patch"), pool, ["id": id, "description": leaked])
        }, field: "description", fragment: "</description>")
        let stored = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT description FROM entities WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(stored, "original")
    }

    func testMemPatchAndReviseRejectLeakedContent() async throws {
        let pool = try makePool()
        let body = try await run(memoryAction("mem_store"), pool, storeParams("original body"))
        let id = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(AnyEncodable(body))) as? [String: Any])["id"] as! String
        let (_, leaked) = ToolCallMarkupLeakFixtures.leaked[5]  // structure-fitting
        await assertRejected({
            _ = try await self.run(self.memoryAction("mem_patch"), pool, ["id": id, "content": leaked])
        }, field: "content", fragment: "</description>")
        await assertRejected({
            _ = try await self.run(self.memoryAction("mem_revise"), pool, ["originalId": id, "content": leaked])
        }, field: "content", fragment: "</description>")
        let stored = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM memories WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(stored, "original body")
        let n = try await count(pool, "SELECT COUNT(*) FROM memories")
        XCTAssertEqual(n, 1, "a rejected revise must not insert its new row")
    }

    // MARK: - Fixture: a memory about this bug

    /// The 2026-10-10 task text, verbatim: it quotes both leaked shapes inline.
    static let quotingMemory = #"""
    Problem: a model's malformed tool call can leak its own parameter markup into a stored text field. On 2026-10-10 a sweep of all 1,129 entities found 6 whose description ended in "</description>\n<parameter name=\"attributes\">{...}" or "</description>\n</invoke>": Stand up 2026-09-14, Stand up 2026-08-18, ADA-558, PR-573, Rationalization Detection, structure-fitting. The 2 meetings also lost their attributes (null), since the real attributes JSON sat inside the leaked tail. All 6 were repaired by hand (mem_entity_patch, verified byte-equal against the pre-leak text), plus Location Engine Demo Day 2026-08-21 on 10/09. Nothing prevents the next one.
    """#
}

/// Type-erases the handler's `any Encodable` so JSONEncoder can encode it.
private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
