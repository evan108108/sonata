import XCTest
import GRDB
@testable import Sonata

/// Edits keep an author's l0/l1 on feelings and reflections (2026-10-26).
/// mem_patch with new content and no l0/l1 used to re-run pith over the
/// author's abstract (feeling aab518c1: the new l1 went third person and lost
/// the texture), and mem_revise had no l0/l1 params at all, so every revise
/// was re-pithed and its author repaired it with a follow-up patch.
final class AuthorAbstractKeepTests: XCTestCase {

    private static let stub = Pith.Result(l0: "PITH L0", l1: "PITH L1")

    /// Counts calls so a test can show pith was never reached.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func action(_ name: String) -> SonataAction {
        memoryActions.first { $0.name == name }!
    }

    /// Store through the real handler with the author's own l0/l1.
    private func store(_ pool: DatabasePool, type: String, l0: String, l1: String) async throws -> String {
        let response = try await action("mem_store").handler(ActionContext(params: ActionParams([
            "content": "original body", "type": type, "l0": l0, "l1": l1,
            "source": "tests", "importance": 3,
        ]), dbPool: pool))
        return try json(response)["id"] as? String ?? ""
    }

    private func abstracts(_ pool: DatabasePool, _ id: String) async throws -> (String?, String?) {
        try await pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT l0, l1 FROM memories WHERE id = ?", arguments: [id])
            return (row?["l0"], row?["l1"])
        }
    }

    private func run<T>(counting counter: CallCounter, _ body: () async throws -> T) async rethrows -> T {
        try await Pith.$generateOverride.withValue({ _ in counter.hit(); return Self.stub }) {
            try await body()
        }
    }

    private func json(_ value: any Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(AuthorAbstractEncodableShim(value: value))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: mem_patch

    func testPatchingFeelingContentKeepsAbstracts() async throws {
        let pool = try makePool()
        let id = try await store(pool, type: "feeling", l0: "I don't mind the fence.", l1: "Not offense; calm.")
        let counter = CallCounter()
        let r = try await run(counting: counter) {
            try json(try await action("mem_patch").handler(ActionContext(params: ActionParams([
                "id": id, "content": "edited body", "revisionNote": "fixed a clause",
            ]), dbPool: pool)))
        }
        let (l0, l1) = try await abstracts(pool, id)
        XCTAssertEqual(l0, "I don't mind the fence.")
        XCTAssertEqual(l1, "Not offense; calm.")
        XCTAssertEqual(counter.count, 0, "pith must not run for a feeling edit")
        XCTAssertEqual(r["abstractsKept"] as? Bool, true)
        XCTAssertEqual(r["note"] as? String, Pith.abstractsKeptNote)
    }

    /// The effective type is the new one when the patch also changes type.
    func testPatchRetypingToReflectionKeepsAbstracts() async throws {
        let pool = try makePool()
        let id = try await store(pool, type: "observation", l0: "author l0", l1: "author l1")
        let counter = CallCounter()
        _ = try await run(counting: counter) {
            try await action("mem_patch").handler(ActionContext(params: ActionParams([
                "id": id, "content": "edited body", "type": "reflection",
            ]), dbPool: pool))
        }
        let (l0, _) = try await abstracts(pool, id)
        XCTAssertEqual(l0, "author l0")
        XCTAssertEqual(counter.count, 0)
    }

    func testPatchingLearningContentStillRegenerates() async throws {
        let pool = try makePool()
        let id = try await store(pool, type: "learning", l0: "old l0", l1: "old l1")
        let counter = CallCounter()
        let r = try await run(counting: counter) {
            try json(try await action("mem_patch").handler(ActionContext(params: ActionParams([
                "id": id, "content": "edited body",
            ]), dbPool: pool)))
        }
        let (l0, l1) = try await abstracts(pool, id)
        XCTAssertEqual(l0, "PITH L0")
        XCTAssertEqual(l1, "PITH L1")
        XCTAssertEqual(counter.count, 1)
        XCTAssertNil(r["abstractsKept"], "the flag appears only when abstracts were kept")
        XCTAssertNil(r["note"])
    }

    func testPatchingFeelingWithSuppliedAbstractsStoresThem() async throws {
        let pool = try makePool()
        let id = try await store(pool, type: "feeling", l0: "old l0", l1: "old l1")
        let counter = CallCounter()
        let r = try await run(counting: counter) {
            try json(try await action("mem_patch").handler(ActionContext(params: ActionParams([
                "id": id, "content": "edited body", "l0": "new l0", "l1": "new l1",
            ]), dbPool: pool)))
        }
        let (l0, l1) = try await abstracts(pool, id)
        XCTAssertEqual(l0, "new l0")
        XCTAssertEqual(l1, "new l1")
        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(r["abstractsKept"])
    }

    // MARK: mem_revise

    func testReviseWithSuppliedAbstractsStoresThemVerbatim() async throws {
        let pool = try makePool()
        let orig = try await store(pool, type: "learning", l0: "old l0", l1: "old l1")
        let counter = CallCounter()
        let r = try await run(counting: counter) {
            try json(try await action("mem_revise").handler(ActionContext(params: ActionParams([
                "originalId": orig, "content": "revised body",
                "l0": "  Verbatim l0, not offense. ", "l1": "Verbatim l1.",
            ]), dbPool: pool)))
        }
        let newId = try XCTUnwrap(r["id"] as? String)
        let (l0, l1) = try await abstracts(pool, newId)
        XCTAssertEqual(l0, "  Verbatim l0, not offense. ")
        XCTAssertEqual(l1, "Verbatim l1.")
        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(r["abstractsKept"])
    }

    func testRevisingReflectionWithoutAbstractsCopiesOriginals() async throws {
        let pool = try makePool()
        let orig = try await store(pool, type: "reflection", l0: "orig l0", l1: "orig l1")
        let counter = CallCounter()
        let r = try await run(counting: counter) {
            try json(try await action("mem_revise").handler(ActionContext(params: ActionParams([
                "originalId": orig, "content": "revised body", "revisionNote": "new data",
            ]), dbPool: pool)))
        }
        let newId = try XCTUnwrap(r["id"] as? String)
        XCTAssertNotEqual(newId, orig)
        let (l0, l1) = try await abstracts(pool, newId)
        XCTAssertEqual(l0, "orig l0")
        XCTAssertEqual(l1, "orig l1")
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(r["abstractsKept"] as? Bool, true)
        XCTAssertEqual(r["note"] as? String, Pith.abstractsKeptNote)
    }

    func testRevisingLearningWithoutAbstractsStillRegenerates() async throws {
        let pool = try makePool()
        let orig = try await store(pool, type: "learning", l0: "orig l0", l1: "orig l1")
        let counter = CallCounter()
        let r = try await run(counting: counter) {
            try json(try await action("mem_revise").handler(ActionContext(params: ActionParams([
                "originalId": orig, "content": "revised body",
            ]), dbPool: pool)))
        }
        let newId = try XCTUnwrap(r["id"] as? String)
        let (l0, _) = try await abstracts(pool, newId)
        XCTAssertEqual(l0, "PITH L0")
        XCTAssertEqual(counter.count, 1)
    }
}

private struct AuthorAbstractEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
