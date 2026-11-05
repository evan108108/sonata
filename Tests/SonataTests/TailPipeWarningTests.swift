import XCTest
import GRDB
@testable import Sonata

/// A job piped into tail without pipefail records tail's exit code (always 0),
/// not the command's (2026-11-05: scout-machine-drift-report exited 3 and its
/// row read lastExitCode 0). scheduler_create warns and never rejects.
final class TailPipeWarningTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func create(_ pool: DatabasePool, _ params: [String: Any]) async throws -> [String: Any] {
        let action = schedulerActions.first { $0.name == "scheduler_create" }!
        let response = try await action.handler(ActionContext(params: ActionParams(params), dbPool: pool))
        let data = try JSONEncoder().encode(TailPipeEncodableShim(value: response))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - detection

    func testTailPipeWithoutPipefailWarns() {
        let warning = TailPipeSemantics.scheduledJobWarning(command: "/bin/bash run.sh 2>&1 | tail -c 1200")
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("set -o pipefail; "), warning!)
    }

    func testTailPipeWithoutSpaceWarns() {
        XCTAssertNotNil(TailPipeSemantics.scheduledJobWarning(command: "node x.js|tail -n 5"))
    }

    func testTailPipeWithPipefailIsQuiet() {
        XCTAssertNil(TailPipeSemantics.scheduledJobWarning(
            command: "set -o pipefail; /opt/homebrew/bin/node check.js 2>&1 | tail -c 1500"))
    }

    func testNoTailIsQuiet() {
        XCTAssertNil(TailPipeSemantics.scheduledJobWarning(command: "gh pr list | jq length"))
        XCTAssertNil(TailPipeSemantics.scheduledJobWarning(command: "echo hi"))
    }

    func testOrTailIsNotAPipe() {
        // `a || tail` runs tail only when a fails; it is not a pipeline.
        XCTAssertNil(TailPipeSemantics.scheduledJobWarning(command: "false || tail -n 1 log.txt"))
    }

    func testTailAsSubstringIsNotTail() {
        XCTAssertNil(TailPipeSemantics.scheduledJobWarning(command: "cat a | tailscale status"))
    }

    // MARK: - scheduler_create

    func testSchedulerCreateTailWithoutPipefailWarnsAndStoresUnchanged() async throws {
        let pool = try makePool()
        let command = "false | tail -c 10"
        let json = try await create(pool, ["name": "t", "schedule": "0 * * * *", "command": command, "enabled": false])
        XCTAssertEqual(json["success"] as? Bool, true, "warn only, never reject")
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("pipefail"), warnings[0])
        let stored = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT command FROM scheduledJobs WHERE name = 't'")
        }
        XCTAssertEqual(stored, command, "the warning does not rewrite the command")
    }

    func testSchedulerCreateTailWithPipefailHasNoWarningsKey() async throws {
        let pool = try makePool()
        let json = try await create(pool, [
            "name": "t", "schedule": "0 * * * *", "command": "set -o pipefail; false | tail -c 10", "enabled": false,
        ])
        XCTAssertEqual(Set(json.keys), ["success"])
    }

    func testSchedulerCreateNotifyTargetAndTailReturnsBothWarnings() async throws {
        let pool = try makePool()
        let json = try await create(pool, [
            "name": "t", "schedule": "0 * * * *", "command": "x | tail", "enabled": false, "notifyTarget": "supervisor",
        ])
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings[0].contains("notifyTarget"), warnings[0])
        XCTAssertTrue(warnings[1].contains("pipefail"), warnings[1])
    }

    // MARK: - the premise, against the real shell

    /// The scheduler runs `/bin/zsh -c`. Pin that zsh reports tail's status
    /// without pipefail and the command's with it, so the warning's claim is
    /// checked rather than asserted.
    func testZshPipelineStatusPremise() throws {
        func status(_ command: String) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", command]
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(try status("false | tail -c 10"), 0)
        XCTAssertEqual(try status("set -o pipefail; false | tail -c 10"), 1)
    }
}

private struct TailPipeEncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
