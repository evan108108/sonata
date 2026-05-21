import XCTest
import GRDB
@testable import Sonata

// Regression tests for session-type persistence (the "Terminal vs Sona" feature).
// Runs the real Sonata migrator (incl. v15_session_kind) against a temp DB and
// exercises InteractiveSessionsStore so the `kind` column round-trips and old
// rows backfill to 'sona' (preserving prior behavior for restored sessions).
final class SessionKindPersistenceTests: XCTestCase {

    private func migratedPool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-sessionkind-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        var migrator = DatabaseMigrator()
        migrator.registerSonataSchema()
        try migrator.migrate(pool)
        return pool
    }

    func testKindRoundTripsThroughStore() throws {
        let pool = try migratedPool()
        InteractiveSessionsStore.upsert(
            dbPool: pool, id: "id-sona", sessionId: "s1", name: "Session 1",
            cwd: "/tmp", position: 0, wasActive: true, kind: "sona")
        InteractiveSessionsStore.upsert(
            dbPool: pool, id: "id-term", sessionId: "s2", name: "Terminal 1",
            cwd: "/tmp", position: 1, wasActive: false, kind: "terminal")

        let rows = InteractiveSessionsStore.loadAll(dbPool: pool)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.id == "id-sona" })?.kind, "sona")
        XCTAssertEqual(rows.first(where: { $0.id == "id-term" })?.kind, "terminal")
    }

    func testUpsertUpdatesKindOnConflict() throws {
        let pool = try migratedPool()
        InteractiveSessionsStore.upsert(
            dbPool: pool, id: "x", sessionId: "s", name: "n",
            cwd: "/tmp", position: 0, wasActive: false, kind: "sona")
        // Re-upsert same id with a different kind — ON CONFLICT must update it.
        InteractiveSessionsStore.upsert(
            dbPool: pool, id: "x", sessionId: "s", name: "n",
            cwd: "/tmp", position: 0, wasActive: false, kind: "terminal")
        XCTAssertEqual(InteractiveSessionsStore.loadAll(dbPool: pool).first?.kind, "terminal")
    }

    func testV15ColumnDefaultsToSonaWhenOmitted() throws {
        // The v15 column is NOT NULL DEFAULT 'sona', so a row inserted without
        // a kind (the shape of any pre-feature row) reads back as 'sona' — i.e.
        // restored legacy sessions keep behaving as Claude Code subprocesses.
        let pool = try migratedPool()
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO interactiveSessions
                    (id, sessionId, name, cwd, position, wasActive, createdAt, updatedAt)
                VALUES ('legacy', 's', 'Old Session', '/tmp', 0, 0, 0, 0)
                """)
        }
        XCTAssertEqual(
            InteractiveSessionsStore.loadAll(dbPool: pool).first(where: { $0.id == "legacy" })?.kind,
            "sona")
    }

    func testSessionKindRawValueParsing() {
        XCTAssertEqual(SessionKind(rawValue: "sona"), .sona)
        XCTAssertEqual(SessionKind(rawValue: "terminal"), .terminal)
        XCTAssertNil(SessionKind(rawValue: "future-type"))
        // The bootstrap path uses `?? .sona`, so an unknown persisted value
        // degrades safely to the default rather than dropping the session.
        XCTAssertEqual(SessionKind(rawValue: "future-type") ?? .sona, .sona)
        XCTAssertEqual(Set(SessionKind.allCases), [.sona, .terminal])
    }
}
