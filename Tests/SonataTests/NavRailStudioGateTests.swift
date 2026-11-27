import XCTest
import GRDB
@testable import Sonata

/// The Studio rail entry follows the `sonata-studio` plugin row. On main
/// before this change the entry was unconditional, so a disabled plugin
/// still offered a tab whose view talks to routes that aren't there
/// (branch studio-navrail-plugin-gate 73884f2, 2026-05-13).
final class NavRailStudioGateTests: XCTestCase {

    func testLivePluginStatuses() {
        for status in ["enabled", "starting", "running"] {
            XCTAssertTrue(NavRailCounts.isLivePluginStatus(status), status)
        }
        for status in ["disabled", "failed", "installed", ""] {
            XCTAssertFalse(NavRailCounts.isLivePluginStatus(status), status)
        }
        XCTAssertFalse(NavRailCounts.isLivePluginStatus(nil), "no plugin row")
    }

    func testVisibleItemsDropsOnlyStudio() {
        let items = [
            NavRailItem(tab: .dashboard, label: "Dashboard", systemImage: "a"),
            NavRailItem(tab: .studio, label: "Studio", systemImage: "b"),
            NavRailItem(tab: .plugins, label: "Plugins", systemImage: "c"),
        ]
        XCTAssertEqual(NavRailCounts.visibleItems(items, studioPluginEnabled: true).map(\.tab),
                       [.dashboard, .studio, .plugins])
        XCTAssertEqual(NavRailCounts.visibleItems(items, studioPluginEnabled: false).map(\.tab),
                       [.dashboard, .plugins])
    }

    /// The real observation, against the real schema: disabling the row
    /// hides Studio, and bringing it back up shows it again.
    @MainActor
    func testObservationFollowsThePluginRow() async throws {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO plugins (name, version, port, status, path, installedAt, updatedAt)
                VALUES (?, '1.0.0', 4999, 'disabled', '/tmp/x', ?, ?)
            """, arguments: [NavRailCounts.studioPluginName, now, now])
        }

        let counts = NavRailCounts()
        XCTAssertTrue(counts.studioPluginEnabled, "starts true so a running Studio doesn't flicker at launch")
        counts.start(dbPool: pool)
        defer { counts.stop() }

        try await waitUntil { !counts.studioPluginEnabled }

        try await pool.write { db in
            try db.execute(sql: "UPDATE plugins SET status = 'running' WHERE name = ?",
                           arguments: [NavRailCounts.studioPluginName])
        }
        try await waitUntil { counts.studioPluginEnabled }

        try await pool.write { db in
            try db.execute(sql: "DELETE FROM plugins WHERE name = ?",
                           arguments: [NavRailCounts.studioPluginName])
        }
        try await waitUntil { !counts.studioPluginEnabled }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
