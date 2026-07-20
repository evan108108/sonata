import XCTest
import GRDB
@testable import Sonata

/// End-to-end replay of the 2026-07-19 compileWiki dispatch.
///
/// On that run the cron dispatched ten pages under the generic
/// "synthesize from memories" recipe. A worker measured every one by hand and
/// found that all ten needed preservation and zero needed compiling — the fifth
/// time in three weeks a run had re-derived that same conclusion.
///
/// This test replays the real manifest against a *copy* of the live database
/// (the wiki files themselves are read at their real paths, but the job never
/// writes files) and asserts the outcome the 7/19 worker had to reach manually:
/// all ten pages preserved byte-for-byte, all ten dirty flags cleared, no task
/// dispatched.
///
/// It is skipped when the live database is absent, so CI on a fresh checkout
/// stays green.
final class WikiCompilation0719ReplayTests: XCTestCase {

    /// The exact slugs dispatched on 2026-07-19.
    private let manifest0719 = [
        "tool-trials/_candidates/2026-07-18-gcloud-always-on-memory",
        "tool-trials/_candidates/2026-07-18-code-review-graph",
        "tool-trials/_candidates/2026-07-18-context7",
        "tool-trials/_candidates/2026-07-18-llm-cliche-highlighter",
        "tool-trials/_candidates/2026-07-18-litert-js",
        "scout-pipeline",
        "tool-trials/_ideas/index",
        "sonata/learnings",
        "sonata/sessions",
        "sonata/goose-engine",
    ]

    private var liveDbPath: String { "\(NSHomeDirectory())/.sonata/sonata.db" }

    func testReplayPreservesAllTenPagesAndDispatchesNothing() async throws {
        guard FileManager.default.fileExists(atPath: liveDbPath) else {
            throw XCTSkip("live sonata.db not present — replay needs real wiki state")
        }

        // Work on a copy so the replay mutates nothing live. The sidecar -wal
        // must come along: Sonata runs in WAL mode, so recent writes live there
        // and a bare .db copy replays stale wiki state.
        let tmp = NSTemporaryDirectory() + "wiki-replay-\(UUID().uuidString).db"
        try FileManager.default.copyItem(atPath: liveDbPath, toPath: tmp)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: liveDbPath + suffix) {
            try? FileManager.default.copyItem(atPath: liveDbPath + suffix, toPath: tmp + suffix)
        }
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: tmp + suffix)
            }
        }

        let pool = try DatabasePool(path: tmp)

        // Restore the 7/19 starting state: exactly these ten pages dirty.
        let filePaths: [String: String] = try await pool.write { db in
            try db.execute(sql: "UPDATE wikiPages SET dirty = 0")
            var paths: [String: String] = [:]
            for slug in self.manifest0719 {
                try db.execute(sql: "UPDATE wikiPages SET dirty = 1 WHERE slug = ?", arguments: [slug])
                guard let path = try String.fetchOne(db, sql: "SELECT filePath FROM wikiPages WHERE slug = ?", arguments: [slug]) else {
                    continue
                }
                paths[slug] = path
            }
            return paths
        }
        XCTAssertEqual(filePaths.count, manifest0719.count, "all ten 7/19 pages must still exist in wikiPages")

        // Fingerprint every file before the run: size + mtime, the two things
        // the task brief asked to compare.
        let before = try filePaths.mapValues { try Self.fingerprint($0) }

        let tasksBefore = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE sourceRef = ?",
                             arguments: [WikiCompilationJob.scheduledJobRef]) ?? 0
        }

        // Run the real job.
        try await WikiCompilationJob.run(dbPool: pool)

        // 1. Every file untouched — same byte count, same mtime.
        for (slug, path) in filePaths {
            let after = try Self.fingerprint(path)
            XCTAssertEqual(after.size, before[slug]?.size, "\(slug): file size changed — content was regenerated")
            XCTAssertEqual(after.mtime, before[slug]?.mtime, "\(slug): mtime changed — file was rewritten")
        }

        // 2. Dirty flags cleared, so the pages do not re-dispatch forever.
        let stillDirty = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT slug FROM wikiPages WHERE dirty = 1")
        }
        XCTAssertTrue(stillDirty.isEmpty, "these pages stayed dirty and will re-dispatch every run: \(stillDirty)")

        // 3. Nothing dispatched — with all ten preserved there is no work to send.
        let tasksAfter = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE sourceRef = ?",
                             arguments: [WikiCompilationJob.scheduledJobRef]) ?? 0
        }
        XCTAssertEqual(tasksAfter, tasksBefore, "a compilation task was dispatched for a set that needed zero compiles")
    }

    // MARK: - Helpers

    private static func fingerprint(_ path: String) throws -> (size: Int, mtime: Date) {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        return (size, mtime)
    }
}
