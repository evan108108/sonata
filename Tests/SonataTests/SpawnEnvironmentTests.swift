import XCTest
@testable import Sonata

// Spawned processes used to inherit Sonata's bare launchd environment (11/16):
// - worker claude processes had no SHELL=, so the zsh-trap hook's $SHELL gate
//   never fired in any worker;
// - scheduler shell jobs had no /opt/homebrew/bin on PATH, so `node` and `gh`
//   exited 127 (ae192-breaker-observation, check-eyebrowse-prs/-github).
final class SpawnEnvironmentTests: XCTestCase {

    private func value(_ key: String, in env: [String]) -> String? {
        env.first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    // MARK: worker / interactive env

    func testWorkerEnvironmentCarriesShell() {
        let env = WorkerCoordinator.buildEnvironment(workerId: "worker-spawnenv-test")
        let shell = value("SHELL", in: env)
        XCTAssertNotNil(shell, "worker env has no SHELL=: \(env.filter { !$0.contains("TOKEN") && !$0.contains("KEY") })")
        XCTAssertFalse(shell?.isEmpty ?? true)
        XCTAssertEqual(shell, SpawnEnvironment.shell())
    }

    @MainActor
    func testInteractiveSessionEnvironmentCarriesShell() {
        let env = InteractiveSessionTab.buildEnvironment(sessionId: "session-spawnenv-test")
        XCTAssertEqual(value("SHELL", in: env), SpawnEnvironment.shell())
    }

    func testWorkerEnvironmentPathHasHomebrew() {
        let env = WorkerCoordinator.buildEnvironment(workerId: "worker-spawnenv-test")
        let path = value("PATH", in: env) ?? ""
        XCTAssertTrue(path.split(separator: ":").contains("/opt/homebrew/bin"), "PATH=\(path)")
    }

    // MARK: scheduler shell jobs

    /// Runs a real job with a launchd-style base environment. The marker proves
    /// the job's env is built from `baseEnvironment` (without the
    /// `process.environment` assignment the child would inherit the test
    /// runner's env and the marker would be empty); the PATH check proves the
    /// merge ran on it.
    func testSchedulerShellJobPathContainsHomebrew() async throws {
        let base = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "SONATA_SPAWN_ENV_MARKER": "m1",
        ]
        let output = try await SchedulerActor.runShellCommand(
            #"print -r -- "$SONATA_SPAWN_ENV_MARKER|$SHELL|$PATH""#,
            baseEnvironment: base
        )
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts.count, 3, "output: \(output)")
        XCTAssertEqual(parts.first, "m1", "job env was not built from baseEnvironment")
        XCTAssertEqual(parts.dropFirst().first, "/bin/zsh", "no SHELL in base → /bin/zsh")
        let path = parts.last ?? ""
        XCTAssertTrue(path.split(separator: ":").contains("/opt/homebrew/bin"), "PATH=\(path)")
        XCTAssertTrue(path.hasSuffix("/usr/bin:/bin:/usr/sbin:/sbin"), "base PATH must be kept: \(path)")
    }

    // MARK: helper

    func testShellFallsBackToZshWhenUnsetOrEmpty() {
        XCTAssertEqual(SpawnEnvironment.shell(from: [:]), "/bin/zsh")
        XCTAssertEqual(SpawnEnvironment.shell(from: ["SHELL": ""]), "/bin/zsh")
        XCTAssertEqual(SpawnEnvironment.shell(from: ["SHELL": "/bin/bash"]), "/bin/bash")
    }

    /// The old copies used a substring test, so "/usr/bin" in PATH made "/bin"
    /// look present. Membership is now by whole component.
    func testMergedPathComparesWholeComponents() {
        let merged = SpawnEnvironment.mergedPath(home: "/Users/x", currentPath: "/usr/bin")
        let parts = merged.split(separator: ":").map(String.init)
        XCTAssertTrue(parts.contains("/bin"), merged)
        XCTAssertEqual(parts.filter { $0 == "/usr/bin" }.count, 1, merged)
        XCTAssertEqual(parts.last, "/usr/bin", "existing PATH is kept at the end: \(merged)")
    }

    func testMergedPathLeavesCompletePathUnchanged() {
        let full = SpawnEnvironment.commonPaths(home: "/Users/x").joined(separator: ":")
        XCTAssertEqual(SpawnEnvironment.mergedPath(home: "/Users/x", currentPath: full), full)
        XCTAssertEqual(SpawnEnvironment.mergedPath(home: "/Users/x", currentPath: nil), full)
    }
}
