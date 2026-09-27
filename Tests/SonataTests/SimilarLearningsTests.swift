import XCTest
import GRDB
@testable import Sonata

/// Regression tests for the similar-learnings warning on mem_store.
///
/// The incident, 2026-09-26: five HS-guide research workers each stored a "reusable
/// techniques" learning (3983d3a7, 54293ef2, 6b37fc93, 21aba24c, 67aa526c).
/// Nothing noticed until a 03:00Z consolidation read them side by side. These
/// tests replay the real bodies (SimilarLearningsFixtures) through the real
/// handler on the real migrator schema, and assert on WHICH ids the warning
/// names, not just that a warning appeared.
///
/// What the replay actually shows: the five are two clusters, not one.
///   * 3983d3a7 / 54293ef2 / 6b37fc93 — picture-book techniques (PSAL team-page
///     hash route, Instagram, Maps photos). #2 and #3 repeat #1.
///   * 21aba24c / 67aa526c — discovery techniques (MySchools admissions, Maps
///     depart-at URL, hijacked Open Data websites). #5 repeats #4.
/// 21aba24c shares at most one distinctive word with the three before it (a
/// generic "maps"/"evaluate"), so in a strict date-order replay of only these
/// five it is the FIRST of its cluster and correctly gets no warning. Any gate
/// loose enough to fire there also fires on the unrelated column decision through
/// "school". The test that shows 21aba24c is still detectable replays its
/// twin first.
///
/// Corpus statistics: rarity weighting ("psal" is distinctive, "school" is not)
/// needs a real corpus. In a 2-7 row test database every shared word looks
/// rare, and no weighting separates the repeats from the unrelated pair. So
/// these tests inject the live corpus's document frequencies for the fixture
/// vocabulary (SimilarLearningsCorpusStats, counts only), which reproduces the
/// conditions the incident happened under. The FTS-backed default is covered
/// separately by testDistinctiveTermsPreferRareWords.
final class SimilarLearningsTests: XCTestCase {

    private typealias Fixture = SimilarLearningsFixtures.Fixture
    private let project = "hs-guide"

    static let liveCorpus = LearningSimilarity.TermStatistics(
        total: { SimilarLearningsCorpusStats.total },
        documentFrequency: { SimilarLearningsCorpusStats.documentFrequency[$0] ?? 1 }
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
    private func storeMemory(
        _ pool: DatabasePool,
        content: String,
        createdAt: Int64,
        type: String = "learning",
        project: String? = "hs-guide"
    ) async throws -> (id: String, body: [String: Any]) {
        var params: [String: Any] = [
            "content": content,
            "type": type,
            "createdAt": Int(createdAt),
            "l0": "l0",
            "l1": "l1",
        ]
        if let project { params["project"] = project }
        let response = try await store.handler(ActionContext(params: ActionParams(params), dbPool: pool))
        let body = try json(response)
        return (body["id"] as? String ?? "", body)
    }

    private func store(_ pool: DatabasePool, _ fixture: Fixture, type: String = "learning") async throws -> (id: String, body: [String: Any]) {
        try await storeMemory(pool, content: fixture.content, createdAt: fixture.createdAt, type: type)
    }

    private func json(_ value: any Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(SimilarLearningsEncodableShim(value: value))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Ids named by the structured field, in rank order.
    private func similarIds(_ body: [String: Any]) -> [String] {
        (body["similarRecentLearnings"] as? [String: Any])?["ids"] as? [String] ?? []
    }

    // MARK: - Acceptance 1: the 2026-09-26 replay

    func testReplayOfSeptember26TechniqueLearningsWarnsOnEveryRepeat() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self

        let first = try await store(pool, f.psalTechniquesBatch1)
        XCTAssertTrue(similarIds(first.body).isEmpty, "the first learning has nothing to repeat; got \(first.body)")
        XCTAssertNil(first.body["warnings"])

        let second = try await store(pool, f.psalTechniquesBatch2)
        XCTAssertEqual(similarIds(second.body), [first.id],
            "54293ef2 repeats 3983d3a7's PSAL hash route, Instagram and Maps-photo techniques")

        let third = try await store(pool, f.psalTechniquesBatch8)
        XCTAssertEqual(similarIds(third.body), [first.id],
            "6b37fc93 repeats 3983d3a7's PSAL team page (schoolid), Instagram and image-size techniques; it shares only 3 distinctive terms with 54293ef2, one under the gate")

        let fourth = try await store(pool, f.discoveryQueensTechniques)
        XCTAssertTrue(similarIds(fourth.body).isEmpty,
            "21aba24c is the first MySchools/depart-at learning — it shares at most one generic word with the PSAL cluster, so a warning here would be a false positive")

        let fifth = try await store(pool, f.discoveryManhattanSouthTechniques)
        XCTAssertEqual(similarIds(fifth.body).first, fourth.id,
            "67aa526c repeats 21aba24c's MySchools, depart-at URL and hijacked-website techniques; the twin must rank first")
    }

    func testTheQueensLearningIsFlaggedWhenItsTwinAlreadyExists() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self

        // Twin stored first (shifted just before the Queens one, still in the window).
        let twin = try await storeMemory(
            pool,
            content: f.discoveryManhattanSouthTechniques.content,
            createdAt: f.discoveryQueensTechniques.createdAt - 60_000
        )
        let queens = try await store(pool, f.discoveryQueensTechniques)
        XCTAssertEqual(similarIds(queens.body), [twin.id],
            "21aba24c is detectable — it just has no twin among the three picture-book learnings stored before it")
    }

    // MARK: - Acceptance 2: unrelated same-project learnings stay quiet

    func testUnrelatedSameProjectLearningsProduceNoWarning() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self

        _ = try await store(pool, f.pictureBooksComplete)
        let decision = try await store(pool, f.unrelatedColumnDecision)  // replayed as a learning

        XCTAssertTrue(similarIds(decision.body).isEmpty,
            "the column decision and the picture-books summary share only the word 'school'; got \(decision.body)")
        XCTAssertNil(decision.body["warnings"])
    }

    func testUnrelatedLearningStaysQuietEvenAmongTheTechniqueCluster() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        for fixture in [f.psalTechniquesBatch1, f.psalTechniquesBatch2, f.psalTechniquesBatch8,
                        f.discoveryQueensTechniques, f.discoveryManhattanSouthTechniques] {
            _ = try await store(pool, fixture)
        }
        let decision = try await storeMemory(pool, content: f.unrelatedColumnDecision.content,
                                        createdAt: f.discoveryManhattanSouthTechniques.createdAt + 60_000)
        XCTAssertTrue(similarIds(decision.body).isEmpty, "got \(decision.body)")
    }

    // MARK: - Scope

    func testOnlyLearningsAreChecked() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        _ = try await store(pool, f.psalTechniquesBatch1)
        let observation = try await store(pool, f.psalTechniquesBatch2, type: "observation")
        XCTAssertNil(observation.body["similarRecentLearnings"], "non-learning stores are not checked")
        XCTAssertNil(observation.body["warnings"])
    }

    func testOnlyLearningsAreCandidates() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        _ = try await store(pool, f.psalTechniquesBatch1, type: "observation")
        let second = try await store(pool, f.psalTechniquesBatch2)
        XCTAssertTrue(similarIds(second.body).isEmpty, "an observation is not a learning to consolidate into")
    }

    func testOtherProjectsAreNotCompared() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        _ = try await storeMemory(pool, content: f.psalTechniquesBatch1.content,
                                  createdAt: f.psalTechniquesBatch1.createdAt, project: "scout")
        let second = try await store(pool, f.psalTechniquesBatch2)
        XCTAssertTrue(similarIds(second.body).isEmpty, "a different project is a different bucket")
    }

    func testNullProjectIsItsOwnBucket() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        let first = try await storeMemory(pool, content: f.psalTechniquesBatch1.content,
                                          createdAt: f.psalTechniquesBatch1.createdAt, project: nil)
        let second = try await storeMemory(pool, content: f.psalTechniquesBatch2.content,
                                           createdAt: f.psalTechniquesBatch2.createdAt, project: nil)
        XCTAssertEqual(similarIds(second.body), [first.id],
            "most learnings carry no project (38 of 55 in the week of 2026-09-26); they must still be compared with each other")

        let scoped = try await store(pool, f.psalTechniquesBatch8)
        XCTAssertTrue(similarIds(scoped.body).isEmpty, "a scoped learning is not compared with the NULL bucket")
    }

    func testLearningsOlderThanSevenDaysAreIgnored() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        _ = try await storeMemory(pool, content: f.psalTechniquesBatch1.content,
                                  createdAt: f.psalTechniquesBatch2.createdAt - LearningSimilarity.windowMs - 1)
        let second = try await store(pool, f.psalTechniquesBatch2)
        XCTAssertTrue(similarIds(second.body).isEmpty, "the window is 7 days back from the new memory's createdAt")
    }

    func testArchivedLearningsAreIgnored() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        let first = try await store(pool, f.psalTechniquesBatch1)
        try await pool.write { db in
            try db.execute(sql: "UPDATE memories SET status = 'archived' WHERE id = ?", arguments: [first.id])
        }
        let second = try await store(pool, f.psalTechniquesBatch2)
        XCTAssertTrue(similarIds(second.body).isEmpty, "an archived memory is already consolidated")
    }

    // MARK: - Response shape

    func testWarningNamesFullIdsInBothForms() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        let first = try await store(pool, f.psalTechniquesBatch1)
        let second = try await store(pool, f.psalTechniquesBatch2)

        let structured = second.body["similarRecentLearnings"] as? [String: Any]
        XCTAssertEqual(structured?["kind"] as? String, "similar_recent_learnings")
        XCTAssertEqual(structured?["ids"] as? [String], [first.id])
        XCTAssertEqual(structured?["hint"] as? String, LearningSimilarity.hint)

        let warnings = second.body["warnings"] as? [String] ?? []
        XCTAssertEqual(warnings.count, 1, "got \(second.body)")
        XCTAssertTrue(warnings.first?.contains(first.id) ?? false,
            "the warning must carry the FULL id — a truncated id doesn't resolve in patch/supersede")
        XCTAssertTrue(warnings.first?.hasPrefix("similar_recent_learnings:") ?? false)
        XCTAssertEqual(first.id.count, 32)
    }

    func testTheWriteIsNeverBlocked() async throws {
        let pool = try makePool()
        let f = SimilarLearningsFixtures.self
        _ = try await store(pool, f.psalTechniquesBatch1)
        let second = try await store(pool, f.psalTechniquesBatch2)
        XCTAssertEqual(second.body["success"] as? Bool, true)
        let stored = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories WHERE id = ?", arguments: [second.id])
        }
        XCTAssertEqual(stored, 1, "a similar learning is still stored")
    }

    // MARK: - Tokenizer

    func testFrozenCorpusStatsCoverEveryFixtureTerm() {
        let f = SimilarLearningsFixtures.self
        let fixtures = [f.psalTechniquesBatch1, f.psalTechniquesBatch2, f.psalTechniquesBatch8,
                        f.discoveryQueensTechniques, f.discoveryManhattanSouthTechniques,
                        f.pictureBooksComplete, f.unrelatedColumnDecision]
        let missing = Set(fixtures.flatMap { LearningSimilarity.tokens($0.content) })
            .filter { SimilarLearningsCorpusStats.documentFrequency[$0] == nil }
        XCTAssertEqual(missing, [],
            "the frozen live-corpus table must cover every fixture term, or the replay silently falls back to df=1; regenerate it if the tokenizer or stopwords changed")
    }

    func testTokensSplitLikeFTS5Unicode61AndDropNoise() {
        XCTAssertEqual(
            LearningSimilarity.tokens("PSAL team-profile.aspx#006/28585 — the Café's getTeamScheduleAny, at 8j<unix>"),
            ["psal", "team", "profile", "aspx", "cafe", "getteamscheduleany", "unix"],
            "split on every non-alphanumeric (as unicode61 does), fold case and diacritics, drop numbers, <3-char tokens and stopwords"
        )
    }

    func testDistinctiveTermsPreferRareWords() async throws {
        LearningSimilarity.statisticsOverride = nil  // exercise the memories_fts-backed default
        let pool = try makePool()
        // "school" appears in every stored memory; "getteamscheduleany" in one.
        for i in 0..<5 {
            _ = try await storeMemory(pool, content: "school note number \(i) about the school day", createdAt: 1_000 + Int64(i))
        }
        let terms = try await pool.read { db in
            try LearningSimilarity.distinctiveTerms(db, content: "school school school getteamscheduleany")
        }
        XCTAssertEqual(terms.first, "getteamscheduleany",
            "rarity, not frequency, decides what makes a learning distinctive")
    }
}

private struct SimilarLearningsEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
