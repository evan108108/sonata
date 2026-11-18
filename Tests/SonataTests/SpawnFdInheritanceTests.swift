import XCTest
import Darwin
import SwiftTerm
import SonataSpawn
@testable import Sonata

/// 11/18 HealthMonitor stall (memory c3cf3c8d). A worker forked two seconds
/// into HealthMonitor's first cycle inherited the write end of
/// GhostWorkerReaper's pgrep pipe. pgrep exited, but EOF never came while the
/// worker lived, so OffPoolProcess sat in readDataToEndOfFile for 10 minutes
/// until the 3da3f20 watchdog restarted the loop.
///
/// Two layers, tested separately:
/// 1. Spawn: Sonata's own forkpty (CSources/SonataSpawn) closes every fd above
///    stderr in the child before SwiftTerm execs. These tests fork through the
///    real SwiftTerm entry point, `PseudoTerminalHelpers.fork`, so they fail if
///    SwiftTerm ever stops calling forkpty or the override stops linking.
/// 2. Read: OffPoolProcess finishes at the child's exit plus a bounded grace,
///    even when another process still holds the pipe's write end.
///
/// Inheritance is modelled with raw fork+exec children (libSystem's forkpty,
/// posix_spawn without POSIX_SPAWN_CLOEXEC_DEFAULT) and a shell background job.
/// Foundation's Process closes descriptors in its child, so a Process-based
/// spawn would pass against the unfixed code (see the 7/19 flock test).
final class SpawnFdInheritanceTests: XCTestCase {

    // MARK: - Layer 1: terminal spawns don't inherit descriptors

    /// The 11/18 shape: a Foundation Pipe is open (no FD_CLOEXEC) when a
    /// terminal child is forked. Once the parent drops its write end, the read
    /// end must see EOF promptly: the child holds no copy.
    func testSwiftTermForkDoesNotInheritAnOpenPipe() throws {
        let pipe = Pipe()
        let writeFd = pipe.fileHandleForWriting.fileDescriptor
        XCTAssertEqual(fcntl(writeFd, F_GETFD) & FD_CLOEXEC, 0,
                       "precondition: Foundation's Pipe is inheritable, as in the incident")

        let child = try Self.swiftTermFork("/bin/sleep", ["30"])
        addTeardownBlock { Self.reap(child.pid); close(child.master) }

        try pipe.fileHandleForWriting.close()
        XCTAssertTrue(Self.seesEOF(pipe.fileHandleForReading.fileDescriptor, within: 3),
                      "the terminal child still holds the pipe's write end, so a reader never sees EOF")

        let leaked = try XCTUnwrap(Self.descriptorsAboveStderr(of: child.pid), "could not list the child's fds")
        XCTAssertEqual(leaked, [], "the terminal child kept descriptors above stderr: \(leaked)")
    }

    /// Control: libSystem's own forkpty, the call SwiftTerm made before the
    /// override, DOES leak the pipe. If this ever sees EOF, the harness can't
    /// detect inheritance and the test above certifies nothing.
    func testLibSystemForkptyLeaksThePipe() throws {
        let pipe = Pipe()
        let pid = try Self.libSystemForkptyExec("/bin/sleep", ["30"])
        addTeardownBlock { Self.reap(pid) }

        try pipe.fileHandleForWriting.close()
        XCTAssertFalse(Self.seesEOF(pipe.fileHandleForReading.fileDescriptor, within: 1),
                       "control: a child of libSystem's forkpty should hold the write end")
        let inherited = try XCTUnwrap(Self.descriptorsAboveStderr(of: pid), "could not list the child's fds")
        XCTAssertFalse(inherited.isEmpty, "control: the fd listing should show the inherited descriptors")
    }

    /// Control: posix_spawn without POSIX_SPAWN_CLOEXEC_DEFAULT also leaks it.
    func testPlainPosixSpawnLeaksThePipe() throws {
        let pipe = Pipe()
        let pid = try Self.posixSpawn("/bin/sleep", ["30"])
        addTeardownBlock { Self.reap(pid) }

        try pipe.fileHandleForWriting.close()
        XCTAssertFalse(Self.seesEOF(pipe.fileHandleForReading.fileDescriptor, within: 1),
                       "control: a plain posix_spawn child should hold the write end")
    }

    /// The override still gives the child a real terminal: stdio on the pty
    /// slave and that slave as its controlling tty.
    func testSwiftTermForkStillGivesTheChildAControllingTerminal() throws {
        let child = try Self.swiftTermFork(
            "/bin/sh", ["-c", "test -t 0 && test -t 1 && echo stdio-ok; exec 3</dev/tty && echo ctty-ok"])
        addTeardownBlock { Self.reap(child.pid); close(child.master) }

        let out = Self.readUntil(child.master, contains: "ctty-ok", within: 5)
        XCTAssertTrue(out.contains("stdio-ok"), "stdin/stdout are not the pty: \(out)")
        XCTAssertTrue(out.contains("ctty-ok"), "the pty is not the child's controlling terminal: \(out)")
    }

    func testOverrideIsLinked() {
        XCTAssertEqual(sonata_forkpty_closes_inherited_fds(), 1)
    }

    // MARK: - Layer 2: OffPoolProcess returns at exit

    /// The child exits but a background job keeps its stdout, which is the
    /// pipe's write end: the same state as a worker that inherited it. The run
    /// must come back at exit + grace with what the child wrote.
    func testRunReturnsAtExitWhenAnotherProcessHoldsTheWriteEnd() async throws {
        let started = Date()
        let outcome = await OffPoolProcess.run(
            "/bin/sh", ["-c", "echo before-exit; /bin/sleep 20 & echo $!"], drainGrace: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        let result = try XCTUnwrap(outcome)
        let lines = result.text.split(separator: "\n").map(String.init)
        if let holder = lines.last.flatMap({ pid_t($0) }) { kill(holder, SIGKILL) }

        XCTAssertLessThan(elapsed, 8, "run waited \(elapsed)s for EOF on a write end another process holds")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(lines.first, "before-exit", "output written before exit was lost: \(result.text)")
    }

    /// Output far beyond the 64KB pipe buffer still arrives whole, with the status.
    func testRunCollectsLargeOutputAndStatus() async throws {
        let outcome = await OffPoolProcess.run(
            "/bin/sh", ["-c", "/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' a; exit 3"])
        let result = try XCTUnwrap(outcome)
        XCTAssertEqual(result.stdout.count, 300_000)
        XCTAssertEqual(result.status, 3)
    }

    func testRunReturnsNilWhenSpawnFails() async {
        let outcome = await OffPoolProcess.run("/nonexistent/binary", [])
        XCTAssertNil(outcome)
    }

    /// Many back-to-back runs: the read descriptor is closed each time.
    func testRunDoesNotLeakDescriptors() async throws {
        let before = try XCTUnwrap(Self.descriptorsAboveStderr(of: getpid())).count
        for _ in 0..<40 {
            _ = await OffPoolProcess.run("/bin/echo", ["x"])
        }
        let after = try XCTUnwrap(Self.descriptorsAboveStderr(of: getpid())).count
        XCTAssertLessThan(after - before, 10, "descriptors grew from \(before) to \(after) over 40 runs")
    }

    // MARK: - Helpers

    private static func swiftTermFork(_ exe: String, _ args: [String]) throws -> (pid: pid_t, master: Int32) {
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard let r = PseudoTerminalHelpers.fork(
            andExec: exe, args: [exe] + args, env: ["PATH=/usr/bin:/bin"], desiredWindowSize: &size) else {
            throw NSError(domain: "spawn", code: 1)
        }
        return (r.pid, r.masterFd)
    }

    private typealias ForkptyFn = @convention(c) (
        UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<termios>?, UnsafeMutablePointer<winsize>?) -> pid_t

    /// The pre-override behaviour: libSystem's forkpty, then execv in the child.
    private static func libSystemForkptyExec(_ exe: String, _ args: [String]) throws -> pid_t {
        guard let lib = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW),
              let sym = dlsym(lib, "forkpty") else { throw NSError(domain: "dlsym", code: 1) }
        let forkpty = unsafeBitCast(sym, to: ForkptyFn.self)
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, nil)
        if pid == 0 {
            execv(exe, argv)
            _exit(127)
        }
        guard pid > 0 else { throw NSError(domain: "forkpty", code: Int(errno)) }
        addMasterToClose(master)
        return pid
    }

    private static var mastersToClose: [Int32] = []
    private static func addMasterToClose(_ fd: Int32) { mastersToClose.append(fd) }

    private static func posixSpawn(_ exe: String, _ args: [String]) throws -> pid_t {
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, nil, nil, argv, nil)
        guard rc == 0 else { throw NSError(domain: "posix_spawn", code: Int(rc)) }
        return pid
    }

    /// True when a read on `fd` returns 0 (EOF) within `seconds`.
    private static func seesEOF(_ fd: Int32, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&p, 1, remaining) > 0 else { continue }
            var byte: UInt8 = 0
            if read(fd, &byte, 1) == 0 { return true }
        }
        return false
    }

    private static func readUntil(_ fd: Int32, contains needle: String, within seconds: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(seconds)
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline, !(String(data: out, encoding: .utf8) ?? "").contains(needle) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) > 0 else { continue }
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return String(data: out, encoding: .utf8) ?? ""
    }

    /// nil when the listing fails (e.g. the pid is gone), so a failure can't read as "none".
    private static func descriptorsAboveStderr(of pid: pid_t) -> [Int32]? {
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 4096)
        let size = Int32(fds.count * MemoryLayout<proc_fdinfo>.stride)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard bytes > 0 else { return nil }
        return fds.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
            .map(\.proc_fd).filter { $0 > 2 }
    }

    private static func reap(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        mastersToClose.forEach { close($0) }
        mastersToClose.removeAll()
    }
}
