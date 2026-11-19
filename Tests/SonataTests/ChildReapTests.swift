import XCTest
@testable import Sonata

// reapChildIfExited (11/19): teardownWorker's liveness check and reap.
// SwiftTerm's terminate() cancels its exit monitor, so without this a cycled
// worker's process stays <defunct> until Sonata restarts. Uses a throwaway
// /bin/sleep child; never touches WorkerManager or worker processes.
final class ChildReapTests: XCTestCase {

    private func spawnSleep() throws -> pid_t {
        var pid: pid_t = 0
        let args = ["/bin/sleep", "30"]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, "/bin/sleep", nil, nil, &argv, nil)
        guard rc == 0 else { throw NSError(domain: "posix_spawn", code: Int(rc)) }
        return pid
    }

    private func psStat(_ pid: pid_t) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "stat=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func testRunningChildIsReportedRunning() throws {
        let pid = try spawnSleep()
        defer { kill(pid, SIGKILL); _ = reapChildIfExited(pid) }
        XCTAssertEqual(reapChildIfExited(pid), .running)
    }

    func testTerminatedChildIsReapedAndLeavesNoZombie() throws {
        let pid = try spawnSleep()
        kill(pid, SIGTERM)

        // Positive control: without a reap, the exited child is a zombie.
        var stat = ""
        for _ in 0..<50 where !stat.hasPrefix("Z") {
            stat = psStat(pid)
            usleep(20_000)
        }
        XCTAssertTrue(stat.hasPrefix("Z"), "an exited, unreaped child must show as a zombie; got '\(stat)'")

        XCTAssertEqual(reapChildIfExited(pid), .reaped)
        XCTAssertEqual(psStat(pid), "", "after the reap the pid must be gone from the process table")
        XCTAssertEqual(reapChildIfExited(pid), .notChild, "a second reap finds nothing")
    }

    func testZeroPidIsNotAChild() {
        XCTAssertEqual(reapChildIfExited(0), .notChild)
    }
}
