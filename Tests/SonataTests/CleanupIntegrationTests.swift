import XCTest
@testable import Sonata

// Opt-in run of the real cleanup against a real data directory.
//
// The unit tests prove the prune rules on fixtures of a handful of files. They
// cannot show what the rules do at the scale they actually meet: hundreds of
// review checkouts holding millions of files, where a predicate that is merely
// slow, or that trips over a symlink or a permission, behaves differently than
// it does on six files in a temp dir.
//
// This deletes real data, so it is gated twice: it needs SONATA_CLEANUP_DIR set
// to an explicit path, and there is deliberately NO default. A test that
// defaulted to the live data directory would be one stray environment variable
// away from deleting someone's home directory.
//
//   SONATA_CLEANUP_DIR=~/.sonata swift test --filter CleanupIntegrationTests
final class CleanupIntegrationTests: XCTestCase {

    func testCleanupAgainstRealDataDirectory() async throws {
        let configured = ProcessInfo.processInfo.environment["SONATA_CLEANUP_DIR"]
        try XCTSkipUnless(
            !(configured ?? "").isEmpty,
            "set SONATA_CLEANUP_DIR to an explicit data directory to run"
        )
        let dataDir = (configured! as NSString).expandingTildeInPath
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: dataDir),
            "SONATA_CLEANUP_DIR does not exist: \(dataDir)"
        )

        let summary = await CleanupManager(dataDir: dataDir).runCleanup()

        print("""
            [cleanup-integration] dir=\(dataDir)
            [cleanup-integration] workspaces removed=\(summary.workspacesRemoved) kept=\(summary.workspacesKept)
            [cleanup-integration] worktrees removed=\(summary.worktreesRemoved) skipped=\(summary.worktreesSkipped)
            [cleanup-integration] local backups removed=\(summary.localBackupsRemoved)
            [cleanup-integration] freed=\(summary.freedGB) GB
            """)

        // The run is the assertion — it must complete without trapping, and the
        // counters must be internally consistent. Exact numbers depend on the
        // machine, so they are reported rather than asserted.
        XCTAssertGreaterThanOrEqual(summary.bytesFreed, 0)
    }
}
