import XCTest
import GRDB
import Logging
@testable import Sonata

/// Sessions-index false alarm (2026-11-18). Until then ConversationIndexer
/// reset every transcript on every launch and re-indexed them all. Mid-rebuild
/// the index runs ahead of SUM(chunkCount), because chunkCount is saved only
/// when a file finishes, so two relaunches 15 min apart tripped index_sessions
/// three times and sent an alert with no data lost. Deletes were by id range
/// 0..<chunkCount, so docs above a stale count, or for a session with no state
/// row, leaked forever (18 measured).
///
/// Every "nothing happens" assertion has a control in the same file that makes
/// the mechanism act, so a no-op implementation can't pass.
final class SessionsIndexRebuildTests: XCTestCase {

    // MARK: - Fake engine

    /// In-memory sessions index. Other indexes report unreachable (-1), so
    /// HealthMonitor skips them.
    actor FakeSearch: SearchService {
        var docs: [String: [String: String]] = [:]
        var postedDocs = 0
        var resetCalls = 0
        var pending = 0

        func inject(_ id: String, session: String, chunk: Int) {
            docs[id] = ["id": id, "sessionId": session, "chunk": "\(chunk)"]
        }
        func injectCount(_ n: Int, session: String) {
            for i in 0..<n { inject("\(session)_\(i)", session: session, chunk: i) }
        }
        func setPending(_ n: Int) { pending = n }
        func ids(session: String) -> [String] {
            docs.values.filter { $0["sessionId"] == session }.compactMap { $0["id"] }.sorted()
        }
        func count() -> Int { docs.count }
        func dropAll() { docs.removeAll() }

        func start(dbPool: DatabasePool?) async {}
        func shutdown() async {}
        func isHealthy() async -> Bool { true }
        func ensureIndexes() async {}
        func indexWikiPage(slug: String, title: String, content: String, namespace: String?, filePath: String) async {}
        func removeWikiPage(slug: String) async {}
        func searchWiki(query: String, limit: Int) async -> [SearchResult] { [] }
        func indexArchivedMemory(_ row: MemoryRow) async {}
        func searchArchive(query: String, limit: Int) async -> [SearchResult] { [] }
        func indexDocFile(filename: String, title: String, content: String, filePath: String) async {}
        func removeDocFile(filename: String) async {}
        func searchDocs(query: String, limit: Int) async -> [SearchResult] { [] }
        func indexPrivateFile(filename: String, title: String, content: String, filePath: String) async {}
        func removePrivateFile(filename: String) async {}
        func searchPrivate(query: String, limit: Int) async -> [SearchResult] { [] }
        func indexEmailDocs(_ docs: [[String: String]]) async {}
        func searchEmails(query: String, limit: Int) async -> [SearchResult] { [] }
        func indexSessionChunks(_ batch: [[String: String]]) async {
            for d in batch { if let id = d["id"] { docs[id] = d } }
            postedDocs += batch.count
        }
        func removeSessionChunks(ids: [String]) async { for id in ids { docs[id] = nil } }
        func removeSessionChunks(sessionId: String) async {
            docs = docs.filter { $0.value["sessionId"] != sessionId }
        }
        func removeAllSessionChunks() async { resetCalls += 1; docs.removeAll() }
        func listSessionChunkRefs() async -> [SessionChunkRef]? {
            docs.values.map {
                SessionChunkRef(id: $0["id"] ?? "", sessionId: $0["sessionId"] ?? "",
                                chunk: Int($0["chunk"] ?? "") ?? -1)
            }
        }
        func searchSessions(query: String, limit: Int) async -> [SearchResult] { [] }
        func documentCount(index: String) async -> Int { index == "sessions" ? docs.count : -1 }
        func pendingTaskCount(index: String) async -> Int { index == "sessions" ? pending : 0 }
        func search(query: String, limit: Int) async -> [SearchResult] { [] }
        func backfillWiki(dbPool: DatabasePool) async {}
        func backfillArchive(dbPool: DatabasePool) async {}
        func pruneArchiveOrphans(dbPool: DatabasePool) async -> Int { 0 }
        func backfillDocs() async {}
        func backfillPrivate() async {}
    }

    // MARK: - Helpers

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func makeRoot() throws -> String {
        let root = NSTemporaryDirectory() + "sonata-sessions-\(UUID().uuidString)/proj"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        return root
    }

    /// A transcript whose extracted text spans exactly `chunks` chunks
    /// (one ~11K-char user line per chunk; chunkChars is 12,000).
    private func writeTranscript(root: String, session: String, chunks: Int) throws {
        var lines = ""
        for i in 0..<chunks {
            let text = "line \(i) " + String(repeating: "x", count: 11_000)
            let obj: [String: Any] = ["type": "user", "message": ["content": text]]
            let data = try JSONSerialization.data(withJSONObject: obj)
            lines += String(data: data, encoding: .utf8)! + "\n"
        }
        try lines.write(toFile: root + "/\(session).jsonl", atomically: true, encoding: .utf8)
    }

    private func makeIndexer(_ pool: DatabasePool, _ search: FakeSearch, root: String,
                             settle: TimeInterval = 2) -> ConversationIndexer {
        ConversationIndexer(dbPool: pool, search: search,
                            logger: Logger(label: "test.indexer"),
                            projectsRoot: root, settleTimeoutSeconds: settle)
    }

    private func chunkCount(_ pool: DatabasePool, session: String) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT chunkCount FROM transcriptIndexState WHERE sessionId = ?",
                             arguments: [session]) ?? -1
        }
    }

    // MARK: - 1. Launch no longer resets a consistent index

    func testConsistentIndexIsNotReindexedAtLaunch() async throws {
        let pool = try makePool(), search = FakeSearch(), root = try makeRoot()
        try writeTranscript(root: root, session: "s1", chunks: 3)
        let indexer = makeIndexer(pool, search, root: root)
        await indexer.sweepForTesting()
        let postedBefore = await search.postedDocs
        XCTAssertEqual(postedBefore, 3)
        let countBefore = try await chunkCount(pool, session: "s1")
        XCTAssertEqual(countBefore, 3)

        let outcome = await indexer.backfillMissing()

        XCTAssertFalse(outcome.fullReset)
        let postedAfter = await search.postedDocs
        XCTAssertEqual(postedAfter, postedBefore, "launch must not re-post an index that is already consistent")
        let resets = await search.resetCalls
        XCTAssertEqual(resets, 0)
        let ids = await search.ids(session: "s1")
        XCTAssertEqual(ids, ["s1_0", "s1_1", "s1_2"])
        let rebuilding = await indexer.isRebuilding
        XCTAssertFalse(rebuilding)
    }

    /// Control for test 1, and the 9/16 recovery path: when writes were lost
    /// (index short of SUM(chunkCount)), the launch pass still resets and
    /// re-indexes.
    func testLostWritesStillTriggerFullReset() async throws {
        let pool = try makePool(), search = FakeSearch(), root = try makeRoot()
        try writeTranscript(root: root, session: "s1", chunks: 3)
        try writeTranscript(root: root, session: "s2", chunks: 4)
        let indexer = makeIndexer(pool, search, root: root)
        await indexer.sweepForTesting()
        await search.dropAll()  // the engine lost every write

        let outcome = await indexer.backfillMissing()

        XCTAssertTrue(outcome.fullReset)
        XCTAssertEqual(outcome.resetRows, 2)
        let count = await search.count()
        XCTAssertEqual(count, 7, "the sweep kicked by the reset re-indexes everything")
        let c1 = try await chunkCount(pool, session: "s1")
        let c2 = try await chunkCount(pool, session: "s2")
        XCTAssertEqual(c1 + c2, 7)
    }

    /// An index read while writes are still queued decides nothing: no reset
    /// even though the count looks short.
    func testUnsettledIndexDecidesNothing() async throws {
        let pool = try makePool(), search = FakeSearch(), root = try makeRoot()
        try writeTranscript(root: root, session: "s1", chunks: 8)  // drift 8 > tolerance 5
        let indexer = makeIndexer(pool, search, root: root, settle: 0.1)
        await indexer.sweepForTesting()
        await search.dropAll()
        await search.setPending(4)

        let outcome = await indexer.backfillMissing()

        XCTAssertTrue(outcome.skippedUnsettled)
        XCTAssertFalse(outcome.fullReset)
        let resets = await search.resetCalls
        XCTAssertEqual(resets, 0)
    }

    // MARK: - 2. Prune by session, not by id range

    /// A shrunk transcript used to delete only 0..<recorded chunkCount. Docs
    /// above it (posted by a run that died before saving state) stayed forever.
    func testShrunkTranscriptOverCountIsPruned() async throws {
        let pool = try makePool(), search = FakeSearch(), root = try makeRoot()
        try writeTranscript(root: root, session: "s1", chunks: 2)
        let indexer = makeIndexer(pool, search, root: root)
        await indexer.sweepForTesting()
        for i in 2...6 { await search.inject("s1_\(i)", session: "s1", chunk: i) }

        try writeTranscript(root: root, session: "s1", chunks: 1)  // shrink
        await indexer.sweepForTesting()

        let ids = await search.ids(session: "s1")
        XCTAssertEqual(ids, ["s1_0"], "a shrink must drop every doc of the session, not just 0..<chunkCount")
        let count = try await chunkCount(pool, session: "s1")
        XCTAssertEqual(count, 1)
    }

    /// The launch pass deletes docs no state row accounts for: a session with
    /// no row, and chunks at or above a session's chunkCount. Recorded chunks
    /// stay (control).
    func testLaunchPrunesDocsNoStateRowAccountsFor() async throws {
        let pool = try makePool(), search = FakeSearch(), root = try makeRoot()
        try writeTranscript(root: root, session: "s1", chunks: 3)
        let indexer = makeIndexer(pool, search, root: root)
        await indexer.sweepForTesting()
        await search.injectCount(2, session: "ghost")
        await search.inject("s1_7", session: "s1", chunk: 7)

        let outcome = await indexer.backfillMissing()

        XCTAssertFalse(outcome.fullReset)
        XCTAssertEqual(outcome.prunedDocs, 3)
        let ghost = await search.ids(session: "ghost")
        XCTAssertEqual(ghost, [])
        let s1 = await search.ids(session: "s1")
        XCTAssertEqual(s1, ["s1_0", "s1_1", "s1_2"])
    }

    // MARK: - 3. index_sessions holds while the indexer rebuilds

    private func seedState(_ pool: DatabasePool, chunkTotal: Int) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO transcriptIndexState
                    (path, sessionId, lastSize, lastMtimeMs, lastOffset, chunkCount, indexedAt)
                VALUES ('/tmp/x.jsonl', 'x', 1, 1, 1, ?, 1)
                """, arguments: [chunkTotal])
        }
    }

    private func sessionsResult(_ results: [HealthMonitor.CheckResult]) -> HealthMonitor.CheckResult? {
        results.first { $0.name == "index_sessions" }
    }

    /// The measured 11/18 reading: 1586 docs against SUM(chunkCount) 428
    /// mid-rebuild. Three checks must not produce a single failure.
    func testMidRebuildDoesNotTripSessionsCheck() async throws {
        let pool = try makePool(), search = FakeSearch()
        try await seedState(pool, chunkTotal: 428)
        await search.injectCount(1586, session: "x")
        let monitor = HealthMonitor(dbPool: pool, search: search, sessionsIndexRebuilding: { true })

        for i in 1...3 {
            let r = sessionsResult(await monitor.checkSearchAndEmbeddings(at: Date()))
            XCTAssertNil(r, "check \(i): a mid-rebuild reading must be held, not reported")
        }
    }

    /// Control: the same reading with no rebuild in flight is drift.
    func testSameDriftWithoutRebuildFails() async throws {
        let pool = try makePool(), search = FakeSearch()
        try await seedState(pool, chunkTotal: 428)
        await search.injectCount(1586, session: "x")
        let monitor = HealthMonitor(dbPool: pool, search: search, sessionsIndexRebuilding: { false })

        let r = sessionsResult(await monitor.checkSearchAndEmbeddings(at: Date()))
        XCTAssertEqual(r?.healthy, false)
    }

    /// Meili's own queue counts as in flight, even when the indexer is idle.
    func testQueuedEngineWritesHoldTheCheck() async throws {
        let pool = try makePool(), search = FakeSearch()
        try await seedState(pool, chunkTotal: 1721)
        await search.injectCount(762, session: "x")
        await search.setPending(3)
        let monitor = HealthMonitor(dbPool: pool, search: search, sessionsIndexRebuilding: { false })

        let r = sessionsResult(await monitor.checkSearchAndEmbeddings(at: Date()))
        XCTAssertNil(r)
    }

    /// The hold is capped, so a writer wedged mid-rebuild still alarms: after
    /// the cap, every check fails (no fresh run of holds), reaching 3 strikes.
    func testHoldIsCappedSoAWedgedRebuildStillAlarms() async throws {
        let pool = try makePool(), search = FakeSearch()
        try await seedState(pool, chunkTotal: 428)
        await search.injectCount(1586, session: "x")
        let monitor = HealthMonitor(dbPool: pool, search: search, sessionsIndexRebuilding: { true })

        let cap = HealthMonitor.sessionsIndexMaxHeldChecks
        for _ in 0..<cap {
            let held = sessionsResult(await monitor.checkSearchAndEmbeddings(at: Date()))
            XCTAssertNil(held)
        }
        for i in 1...3 {
            let r = sessionsResult(await monitor.checkSearchAndEmbeddings(at: Date()))
            XCTAssertEqual(r?.healthy, false, "check \(cap + i) past the cap must strike")
        }
    }

    /// A reading within tolerance is reported as healthy during a rebuild too.
    func testInToleranceReadingIsReportedDuringRebuild() async throws {
        let pool = try makePool(), search = FakeSearch()
        try await seedState(pool, chunkTotal: 2862)
        await search.injectCount(2889, session: "x")
        let monitor = HealthMonitor(dbPool: pool, search: search, sessionsIndexRebuilding: { true })

        let r = sessionsResult(await monitor.checkSearchAndEmbeddings(at: Date()))
        XCTAssertEqual(r?.healthy, true)
    }
}
