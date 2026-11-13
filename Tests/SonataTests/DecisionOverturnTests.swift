import XCTest
import GRDB
@testable import Sonata

/// Regression tests for the possibly-overturned warning on mem_store(type: decision).
///
/// The incident, 2026-11-12: decision c9e931e1 (importance 7, do NOT rotate the
/// exposed credentials) was stored beside runbook a564073f (importance 8), which
/// still said to rotate them. Recall ranks by importance, not date, so the runbook
/// kept winning, and nothing flagged the pair (learning 150f95a2). These tests
/// replay that pair (DecisionOverturnFixtures) through the real handler on the real
/// migrator schema, and assert on WHICH ids the warning names.
///
/// Corpus statistics: as in SimilarLearningsTests, rarity weighting needs a real
/// corpus, so the tests inject the live corpus's document frequencies for the
/// fixture vocabulary (DecisionOverturnCorpusStats, counts only).
final class DecisionOverturnTests: XCTestCase {

    private typealias Fixture = DecisionOverturnFixtures.Fixture
    private let f = DecisionOverturnFixtures.self

    static let liveCorpus = LearningSimilarity.TermStatistics(
        total: { DecisionOverturnCorpusStats.total },
        documentFrequency: { DecisionOverturnCorpusStats.documentFrequency[$0] ?? 1 }
    )

    override func setUp() {
        super.setUp()
        LearningSimilarity.statisticsOverride = Self.liveCorpus
    }

    override func tearDown() {
        LearningSimilarity.statisticsOverride = nil
        super.tearDown()
    }

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private var store: SonataAction {
        memoryActions.first { $0.name == "mem_store" }!
    }

    /// Store through the real handler. l0/l1 are supplied so the handler skips
    /// Pith generation (which would reach for the local llama-server).
    private func store(
        _ pool: DatabasePool,
        _ fixture: Fixture,
        type: String,
        importance: Double,
        createdAt: Int64? = nil,
        project: String = "adaptengine"
    ) async throws -> (id: String, body: [String: Any]) {
        let params: [String: Any] = [
            "content": fixture.content,
            "type": type,
            "importance": importance,
            "createdAt": Int(createdAt ?? fixture.createdAt),
            "project": project,
            "l0": "l0",
            "l1": "l1",
        ]
        let response = try await store.handler(ActionContext(params: ActionParams(params), dbPool: pool))
        let data = try JSONEncoder().encode(DecisionOverturnEncodableShim(value: response))
        let body = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (body["id"] as? String ?? "", body)
    }

    /// The 11/12 runbook, as stored: a learning at importance 8.
    private func storeRunbook(
        _ pool: DatabasePool,
        type: String = "learning",
        importance: Double = 8,
        createdAt: Int64? = nil,
        project: String = "adaptengine"
    ) async throws -> String {
        try await store(pool, f.sandboxExecRunbook, type: type, importance: importance,
                        createdAt: createdAt, project: project).id
    }

    /// The 11/12 no-rotation decision, as stored: importance 7.
    private func storeDecision(_ pool: DatabasePool, type: String = "decision") async throws -> [String: Any] {
        try await store(pool, f.noRotationDecision, type: type, importance: 7).body
    }

    private func overturnedIds(_ body: [String: Any]) -> [String] {
        (body["possiblyOverturned"] as? [String: Any])?["ids"] as? [String] ?? []
    }

    // MARK: - (1) Positive: the 2026-11-12 pair

    func testNoRotationDecisionNamesTheRunbookItOverturns() async throws {
        let pool = try makePool()
        let runbook = try await storeRunbook(pool)
        let decision = try await storeDecision(pool)

        let terms = try await pool.read { db in
            try LearningSimilarity.distinctiveTerms(db, content: self.f.noRotationDecision.content)
        }
        XCTAssertEqual(overturnedIds(decision), [runbook],
            "c9e931e1 reverses a564073f's rotation instruction; decision terms were \(terms); got \(decision)")

        let structured = decision["possiblyOverturned"] as? [String: Any]
        XCTAssertEqual(structured?["kind"] as? String, "possibly_overturned")
        XCTAssertEqual(structured?["hint"] as? String, DecisionOverturn.hint)
        XCTAssertEqual(
            DecisionOverturn.hint,
            "If this decision changes how one of these says to do something, mem_patch/mem_revise it with a revisionNote citing this decision."
        )

        let warnings = decision["warnings"] as? [String] ?? []
        XCTAssertEqual(warnings.count, 1, "got \(decision)")
        XCTAssertTrue(warnings.first?.hasPrefix("possibly_overturned:") ?? false)
        XCTAssertTrue(warnings.first?.contains(runbook) ?? false,
            "the warning must carry the FULL id; a truncated id doesn't resolve in mem_patch")
        XCTAssertEqual(runbook.count, 32)
    }

    /// Why the decision check uses 16 terms, gate 5, and not the learnings
    /// check's 8, gate 4: at 8 the decision's rarest words are its reasoning
    /// (overly, cautious, regenerate, audits), and only 3 survive into the runbook.
    func testTheLearningsSettingsWouldMissTheIncident() async throws {
        let pool = try makePool()
        let runbook = try await storeRunbook(pool)
        let decision = f.noRotationDecision
        let (narrow, wide) = try await pool.read { db in (
            try DecisionOverturn.findPossiblyOverturned(
                db, memoryId: "new", content: decision.content, importance: 7, createdAt: decision.createdAt,
                termCount: LearningSimilarity.queryTermCount, minShared: LearningSimilarity.minSharedTerms),
            try DecisionOverturn.findPossiblyOverturned(
                db, memoryId: "new", content: decision.content, importance: 7, createdAt: decision.createdAt)
        ) }
        XCTAssertTrue(narrow.isEmpty, "4-of-8 misses the incident; if this starts passing, revisit queryTermCount")
        XCTAssertEqual(wide.map(\.id), [runbook])
        XCTAssertEqual(wide.first?.sharedTerms, ["access", "rotate", "client", "exec", "key", "api"])
    }

    func testTheWriteIsNeverBlocked() async throws {
        let pool = try makePool()
        _ = try await storeRunbook(pool)
        let decision = try await storeDecision(pool)
        XCTAssertEqual(decision["success"] as? Bool, true)
        let id = decision["id"] as? String ?? ""
        let stored = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(stored, 1, "a decision that overturns something is still stored")
    }

    // MARK: - (2) Control: an unrelated decision

    func testUnrelatedDecisionReportsNothing() async throws {
        let pool = try makePool()
        _ = try await storeRunbook(pool)
        // Same importance as the real decision, so only the terms differ.
        let holiday = try await store(pool, f.fridayOffDecision, type: "decision", importance: 7).body
        XCTAssertTrue(overturnedIds(holiday).isEmpty, "a holiday decision shares nothing with the exec runbook; got \(holiday)")
        XCTAssertNil(holiday["possiblyOverturned"])
        XCTAssertNil(holiday["warnings"])
    }

    // MARK: - (3) Importance floor

    func testCandidateBelowTheImportanceFloorIsExcluded() async throws {
        let pool = try makePool()
        _ = try await storeRunbook(pool, importance: 5)  // floor for an importance-7 decision is 6
        let decision = try await storeDecision(pool)
        XCTAssertTrue(overturnedIds(decision).isEmpty,
            "an instruction well below the decision's importance won't outrank it in recall; got \(decision)")
    }

    func testCandidateExactlyAtTheImportanceFloorIsIncluded() async throws {
        let pool = try makePool()
        let runbook = try await storeRunbook(pool, importance: 6)
        let decision = try await storeDecision(pool)
        XCTAssertEqual(overturnedIds(decision), [runbook], "the floor is inclusive: importance >= decision - 1")
    }

    // MARK: - Scope

    func testOnlyDecisionsAreChecked() async throws {
        let pool = try makePool()
        _ = try await storeRunbook(pool)
        let learning = try await storeDecision(pool, type: "learning")
        XCTAssertNil(learning["possiblyOverturned"], "only type=decision stores run this check")
    }

    func testDecisionsAndFactsAreCandidatesButObservationsAreNot() async throws {
        let pool = try makePool()
        let asDecision = try await storeRunbook(pool, type: "decision")
        let first = try await storeDecision(pool)
        XCTAssertEqual(overturnedIds(first), [asDecision])

        let pool2 = try makePool()
        let asFact = try await storeRunbook(pool2, type: "fact")
        let second = try await storeDecision(pool2)
        XCTAssertEqual(overturnedIds(second), [asFact])

        let pool3 = try makePool()
        _ = try await storeRunbook(pool3, type: "observation")
        let third = try await storeDecision(pool3)
        XCTAssertTrue(overturnedIds(third).isEmpty, "an observation records, it doesn't instruct")
    }

    func testOtherProjectsAreCompared() async throws {
        let pool = try makePool()
        let runbook = try await storeRunbook(pool, project: "sonata")
        let decision = try await storeDecision(pool)
        XCTAssertEqual(overturnedIds(decision), [runbook],
            "a decision can reverse an instruction filed under another project")
    }

    func testInstructionsOlderThanThirtyDaysAreIgnored() async throws {
        let pool = try makePool()
        _ = try await storeRunbook(pool, createdAt: f.noRotationDecision.createdAt - DecisionOverturn.windowMs - 1)
        let decision = try await storeDecision(pool)
        XCTAssertTrue(overturnedIds(decision).isEmpty, "the window is 30 days back from the decision's createdAt")
    }

    func testSupersededAndArchivedInstructionsAreIgnored() async throws {
        for status in ["superseded", "archived"] {
            let pool = try makePool()
            let runbook = try await storeRunbook(pool)
            try await pool.write { db in
                try db.execute(sql: "UPDATE memories SET status = ? WHERE id = ?", arguments: [status, runbook])
            }
            let decision = try await storeDecision(pool)
            XCTAssertTrue(overturnedIds(decision).isEmpty, "a \(status) instruction is already out of recall's way")
        }
    }

    // MARK: - Fixture integrity

    func testFrozenCorpusStatsCoverEveryFixtureTerm() {
        let missing = Set([f.sandboxExecRunbook, f.noRotationDecision, f.fridayOffDecision]
            .flatMap { LearningSimilarity.tokens($0.content) })
            .filter { DecisionOverturnCorpusStats.documentFrequency[$0] == nil }
        XCTAssertEqual(missing, [],
            "the frozen live-corpus table must cover every fixture term, or the replay silently falls back to df=1")
    }
}

private struct DecisionOverturnEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
