import XCTest
import GRDB
import Logging
@testable import Sonata

/// A single new file must dispatch exactly one `file_added` task.
///
/// Drive/Gemini sync lands a meeting transcript in two FS events: the file
/// is created, then replaced at the same path by an atomic rename several
/// seconds later. Both carry Created/Renamed flags, so both classify as
/// `file_added`; the per-watcher `cooldownMs` debounce (5 s on
/// meeting-logger) is shorter than the gap, so the second one dispatched a
/// duplicate `/meeting` task (watcher_events 9a2c2b27 / 03b7d724, 9.1 s
/// apart, 2026-10-08; 5d7a4171 / e0bcc301, 10 s apart, 2026-09-28).
///
/// These tests drive a real FSEventStream against a temp directory, so the
/// event shapes are the ones macOS actually produces. `cooldownMs` is set
/// to 1 s and the replace waits past it, which is the production shape
/// (gap > cooldown) compressed in time.
final class WatcherFileAddedIdempotencyTests: XCTestCase {

    private let watcherId = "test-file-added"
    private let cooldownMs: Int64 = 1_000

    /// Long enough for the stream's 1 s latency plus the actor hop.
    private let settle: UInt64 = 2_500_000_000

    private func makeRunner() async throws -> (WatcherRunner, DatabasePool, String) {
        let (pool, dbPath) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }

        // FSEvents reports /private/var/...; realpath(3) gives the same.
        // (URL.resolvingSymlinksInPath() strips /private, so it doesn't.)
        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-idem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: raw) }
        let dir = URL(fileURLWithPath: realPath(raw.path))

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await pool.write { [watcherId, cooldownMs] db in
            try db.execute(
                sql: """
                INSERT INTO watchers
                    (id, name, path, pattern, recursive, trigger, prompt,
                     enabled, cooldownMs, createdAt, updatedAt)
                VALUES (?, ?, ?, '*.md', 0, 'file_added', '/meeting {{path}}',
                        1, ?, ?, ?)
                """,
                arguments: [watcherId, "idempotency test", dir.path, cooldownMs, now, now]
            )
        }

        let registry = ActionRegistry()
        registry.register(taskActions)
        let runner = WatcherRunner(dbPool: pool, registry: registry)
        await runner.start()
        addTeardownBlock { await runner.shutdown() }

        // The stream starts at "since now" and takes a moment to go live; a
        // write before that is silently missed. Prove it is live with a
        // probe file before any test write.
        let probe = "zz-stream-probe.md"
        try "probe".write(
            toFile: dir.appendingPathComponent(probe).path,
            atomically: false, encoding: .utf8
        )
        let live = try await waitUntil(timeoutMs: 8_000) {
            try await self.dispatchedCount(pool, basename: probe) >= 1
        }
        XCTAssertTrue(live, "FSEventStream never delivered the probe file")
        return (runner, pool, dir.path)
    }

    private func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func waitUntil(
        timeoutMs: Int,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await condition()
    }

    private func dispatchedCount(_ pool: DatabasePool, basename: String) async throws -> Int {
        try await pool.read { [watcherId] db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM watcher_events
                WHERE watcherId = ? AND eventType = 'file_added'
                  AND status = 'dispatched' AND path LIKE ?
                """,
                arguments: [watcherId, "%/" + basename]
            ) ?? 0
        }
    }

    /// Create, then atomically replace the same path after the cooldown,
    /// the way a sync client finalizes a download. Exactly one dispatch.
    func testCreateThenReplaceDispatchesOnce() async throws {
        let (_, pool, dir) = try await makeRunner()
        let name = "Stand up - 2026_10_08 10_30 EDT - Notes by Gemini.md"
        let target = (dir as NSString).appendingPathComponent(name)

        try "draft".write(toFile: target, atomically: false, encoding: .utf8)
        let created = try await waitUntil(timeoutMs: 5_000) {
            try await self.dispatchedCount(pool, basename: name) == 1
        }
        XCTAssertTrue(created, "the create itself must dispatch")
        // Past the cooldown, as in production (gap 9-10 s > cooldown 5 s).
        try await Task.sleep(nanoseconds: UInt64(cooldownMs) * 1_000_000 + 500_000_000)

        // Replace via rename(2) over the existing path, past the cooldown.
        let tmp = (dir as NSString).appendingPathComponent(".sync-\(UUID().uuidString).tmp")
        try "final transcript".write(toFile: tmp, atomically: false, encoding: .utf8)
        XCTAssertEqual(rename(tmp, target), 0, "rename over target failed: errno \(errno)")
        try await Task.sleep(nanoseconds: settle)

        let total = try await dispatchedCount(pool, basename: name)
        XCTAssertEqual(total, 1, "one new file must dispatch exactly one file_added task")
        // Not vacuous: the replace event did arrive and was suppressed.
        let deduped = try await dedupedCount(pool, basename: name)
        XCTAssertGreaterThanOrEqual(deduped, 1, "the replace event should be logged as deduped")
    }

    /// The claim survives a restart: a path with a dispatched file_added in
    /// the event log (a previous app run) does not dispatch again.
    func testPriorDispatchInEventLogSuppressesAfterRestart() async throws {
        let (_, pool, dir) = try await makeRunner()
        let name = "Stand up - 2026_09_28 10_26 EDT - Notes by Gemini.md"
        let target = (dir as NSString).appendingPathComponent(name)
        let earlier = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        try await pool.write { [watcherId] db in
            try db.execute(
                sql: """
                INSERT INTO watcher_events
                    (id, watcherId, path, eventType, firedAt, taskId, status, error)
                VALUES ('prior-run-event', ?, ?, 'file_added', ?, 'prior-task', 'dispatched', NULL)
                """,
                arguments: [watcherId, target, earlier]
            )
        }

        try "replaced after restart".write(toFile: target, atomically: false, encoding: .utf8)
        let suppressed = try await waitUntil(timeoutMs: 5_000) {
            try await self.dedupedCount(pool, basename: name) >= 1
        }
        XCTAssertTrue(suppressed, "the event should be logged as deduped")
        let total = try await dispatchedCount(pool, basename: name)
        XCTAssertEqual(total, 1, "only the prior run's dispatch; no new one")
    }

    private func dedupedCount(_ pool: DatabasePool, basename: String) async throws -> Int {
        try await pool.read { [watcherId] db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM watcher_events
                WHERE watcherId = ? AND status = 'deduped' AND path LIKE ?
                """,
                arguments: [watcherId, "%/" + basename]
            ) ?? 0
        }
    }

    /// Guard against over-dedup: two different files each dispatch once.
    func testDistinctFilesEachDispatch() async throws {
        let (_, pool, dir) = try await makeRunner()
        let a = "Stand up - A.md"
        let b = "Stand up - B.md"
        try "a".write(toFile: (dir as NSString).appendingPathComponent(a), atomically: false, encoding: .utf8)
        try "b".write(toFile: (dir as NSString).appendingPathComponent(b), atomically: false, encoding: .utf8)
        try await Task.sleep(nanoseconds: settle)

        let countA = try await dispatchedCount(pool, basename: a)
        let countB = try await dispatchedCount(pool, basename: b)
        XCTAssertEqual(countA, 1)
        XCTAssertEqual(countB, 1)
    }

    /// The source side of a rename also carries the Renamed flag. A file
    /// moved OUT of the folder is not a new file there.
    func testRenamedAwayPathDoesNotDispatch() async throws {
        let (_, pool, dir) = try await makeRunner()
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-idem-out-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        // Created outside, so the watcher never sees its creation...
        let name = "moved-away.md"
        let staging = outside.appendingPathComponent(name).path
        try "x".write(toFile: staging, atomically: false, encoding: .utf8)
        let inside = (dir as NSString).appendingPathComponent(name)
        // ...moved in and straight back out before the stream delivers.
        XCTAssertEqual(rename(staging, inside), 0)
        XCTAssertEqual(rename(inside, staging), 0)
        try await Task.sleep(nanoseconds: settle)

        let count = try await dispatchedCount(pool, basename: name)
        XCTAssertEqual(count, 0, "a path that no longer exists is not a file_added")
    }
}
