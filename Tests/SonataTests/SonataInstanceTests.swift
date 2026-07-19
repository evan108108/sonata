import XCTest
@testable import Sonata

/// Regression tests for the 2026-07-13 outage: a side-launched dev binary came
/// up alongside /Applications/Sonata.app, republished the fleet's MCP config to
/// its own port, and took the worker channel down with it.
final class SonataInstanceTests: XCTestCase {

    private let home = "/Users/tester"

    // MARK: - Data directory

    func testDataDirectoryDefaultsToDotSonataUnderHome() {
        let dir = SonataInstance.resolveDataDirectory(env: [:], home: home)
        XCTAssertEqual(dir, "/Users/tester/.sonata")
    }

    func testDataDirectoryHonorsEnvOverride() {
        let dir = SonataInstance.resolveDataDirectory(
            env: ["SONATA_DATA_DIR": "/tmp/isolate"], home: home)
        XCTAssertEqual(dir, "/tmp/isolate")
    }

    func testDataDirectoryExpandsTildeInOverride() {
        let dir = SonataInstance.resolveDataDirectory(
            env: ["SONATA_DATA_DIR": "~/sandbox"], home: home)
        XCTAssertFalse(dir.hasPrefix("~"), "tilde must be expanded, not passed to open() literally")
    }

    /// An empty override is a footgun of its own — treat it as unset rather than
    /// resolving the data dir to "/sonata.db".
    func testEmptyOverrideFallsBackToDefault() {
        let dir = SonataInstance.resolveDataDirectory(
            env: ["SONATA_DATA_DIR": ""], home: home)
        XCTAssertEqual(dir, "/Users/tester/.sonata")
    }

    // MARK: - Primary vs secondary
    //
    // Only a primary may rewrite ~/.claude.json, claim the fixed plugin and
    // MeiliSearch ports, or pkill the shared model servers on quit.

    func testDefaultDirAndDefaultPortIsPrimary() {
        XCTAssertTrue(SonataInstance.isPrimary(
            dataDirectory: "/Users/tester/.sonata", port: 3211, home: home))
    }

    /// The failure of 2026-07-13: the real data dir, but a spare port. The old
    /// code happily rewrote the fleet's MCP endpoint to that spare port.
    func testDefaultDirOnSparePortIsNotPrimary() {
        XCTAssertFalse(SonataInstance.isPrimary(
            dataDirectory: "/Users/tester/.sonata", port: 3299, home: home),
            "an instance on a non-default port must never republish the fleet's MCP config")
    }

    func testIsolatedDataDirIsNotPrimary() {
        XCTAssertFalse(SonataInstance.isPrimary(
            dataDirectory: "/tmp/isolate", port: 3211, home: home))
    }

    func testIsolatedDataDirAndSparePortIsNotPrimary() {
        XCTAssertFalse(SonataInstance.isPrimary(
            dataDirectory: "/tmp/isolate", port: 3299, home: home))
    }

    // MARK: - Single-instance lock

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "sonata-lock-test-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func testLockIsAcquiredOnAFreshDataDirectory() {
        XCTAssertTrue(SonataInstance.acquireLock(at: makeTempDir()))
    }

    /// The heart of the fix. flock is held per open file description, so a second
    /// acquisition against the same data dir is refused even from this process —
    /// exactly as it would be from a second Sonata.
    func testSecondLockOnSameDataDirectoryIsRefused() {
        let dir = makeTempDir()
        XCTAssertTrue(SonataInstance.acquireLock(at: dir), "first instance takes the lock")
        XCTAssertFalse(SonataInstance.acquireLock(at: dir), "second instance must yield, not boot")
    }

    /// Why a sandboxed dev binary can run alongside the app: the lock lives
    /// inside the data dir, so a different data dir is a different lock.
    func testLockOnADifferentDataDirectoryIsIndependent() {
        let primary = makeTempDir()
        let secondary = makeTempDir()
        XCTAssertTrue(SonataInstance.acquireLock(at: primary))
        XCTAssertTrue(SonataInstance.acquireLock(at: secondary),
                      "an isolated instance must not be blocked by the primary's lock")
    }

    func testLockCreatesTheDataDirectoryIfMissing() {
        let dir = makeTempDir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
        XCTAssertTrue(SonataInstance.acquireLock(at: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/sonata.lock"))
    }

    // MARK: - Lock must not outlive the process via inherited descriptors
    //
    // 2026-07-19: installing a LaunchAgent with KeepAlive on Scout appeared to
    // work, then failed its own falsification test. SIGKILLing Sonata did
    // restart it (runs 1 -> 2), but the replacement logged "another Sonata
    // already owns /Users/scout/.sonata" and exit(0)d, which KeepAlive
    // {SuccessfulExit: false} correctly reads as "do not restart" — leaving the
    // host down with supervision installed and dormant.
    //
    // Cause: the lock descriptor was opened without O_CLOEXEC, so every forked
    // worker/plugin inherited it. flock is per open-file-description, so those
    // orphans held the data dir locked after their parent died. Same bug class
    // as the :3211 listen socket on 2026-07-17, which got FD_CLOEXEC while the
    // lock file was missed.

    func testLockDescriptorIsCloseOnExec() {
        XCTAssertTrue(SonataInstance.acquireLock(at: makeTempDir()))
        XCTAssertEqual(SonataInstance.lockDescriptorIsCloseOnExec, true,
                       "lock fd must be O_CLOEXEC or forked children keep the lock alive past a crash")
    }

    /// The behavioural form, and the one that actually reproduces the outage:
    /// a live child must not keep the data directory locked once the parent's
    /// descriptor is gone.
    ///
    /// This deliberately does NOT use Foundation's `Process`. On Darwin that
    /// spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT`, which closes every descriptor
    /// regardless of its FD_CLOEXEC flag — so a `Process`-based version of this
    /// test passes even against the unfixed code and certifies nothing (checked:
    /// it did). Sonata's workers come up through SwiftTerm's forkpty, a plain
    /// fork+exec that inherits by default. Raw posix_spawn without that flag is
    /// the faithful model.
    func testChildProcessDoesNotInheritTheLock() throws {
        let dir = makeTempDir()
        XCTAssertTrue(SonataInstance.acquireLock(at: dir), "parent takes the lock")

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sleep"), strdup("30"), nil,
        ]
        defer { argv.forEach { free($0) } }

        let rc = posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ)
        XCTAssertEqual(rc, 0, "failed to spawn the inheriting child")
        addTeardownBlock {
            kill(pid, SIGTERM)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        // Simulate the parent dying. The kernel drops the parent's flock here;
        // any surviving hold can only come from an inherited descriptor.
        SonataInstance.releaseLockForTesting()

        XCTAssertTrue(SonataInstance.acquireLock(at: dir),
                      "a relaunch must be able to take the lock while an orphaned child is alive")
    }
}
