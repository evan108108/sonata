import Foundation
import GRDB
@testable import Sonata

/// Test-side database harness that spins up a tmp SQLite file with Sonata's
/// FULL migrator applied — same code path production uses. Prefer this over
/// hand-rolled `CREATE TABLE` inside individual test files.
///
/// Why: 2026-08-11 sona-worker-2's sonar_dm affinity fix cost me 20 min of
/// mystified debugging because the test harness had a hand-rolled
/// `CREATE UNIQUE INDEX ... WHERE idempotencyKey IS NOT NULL` on
/// workerEvents (the v28 partial form). SQLite's `ON CONFLICT(col) DO
/// NOTHING` rejects every insert against a partial UNIQUE index with
/// "does not match any PRIMARY KEY or UNIQUE constraint" — the exact bug
/// production's v29 migration was written to fix. Because the test hand-
/// rolled the schema, it never saw v29, and every insert threw silently.
///
/// The fix ships whatever's in `registerSonataSchema` — one source of truth
/// for tests and production. When a new migration lands, tests pick it up
/// automatically. When a schema shape changes (partial→full index,
/// column added), tests can't drift out of sync.
///
/// Performance note: the migrator runs all registered migrations against an
/// empty DB. On the M-series it's <100 ms even after 40+ migrations, so
/// there's no per-test cost worth optimizing.
enum TestDatabase {

    /// Open a fresh Sonata database at a temp path with all real migrations
    /// applied. The caller owns cleanup of the file — pass the returned
    /// path to `addTeardownBlock` if this is called from XCTestCase.
    ///
    /// Returns (pool, tmpPath) so the caller can register the teardown.
    static func makePool() throws -> (pool: DatabasePool, path: String) {
        let tmp = NSTemporaryDirectory() + "sonata-test-\(UUID().uuidString).sqlite"
        let pool = try DatabasePool(path: tmp)

        var migrator = DatabaseMigrator()
        migrator.registerSonataSchema()
        try migrator.migrate(pool)

        return (pool: pool, path: tmp)
    }
}
