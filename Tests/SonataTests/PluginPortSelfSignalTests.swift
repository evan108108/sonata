import XCTest
import Darwin
@testable import Sonata

/// 10/26 02:11Z and 10/27 14:25Z: "HTTP server: runService returned
/// unexpectedly" during plugin respawns. PluginManager.killProcessOnPort
/// SIGTERMed every pid from `lsof -ti :<port>`, which matches the client end
/// of a socket too. Sonata holds a connection to each plugin (sonar's events
/// channel on :4000), so it signalled itself, and Hummingbird's ServiceGroup
/// turned the SIGTERM into a graceful HTTP shutdown.
///
/// These tests use a real listener in a child process and a client socket in
/// this one, which is exactly Sonata's position.
final class PluginPortSelfSignalTests: XCTestCase {

    private var listener: Process?

    override func tearDown() {
        if let listener, listener.isRunning { listener.terminate() }
        listener = nil
        super.tearDown()
    }

    /// A free loopback port, found by binding :0 and reading it back.
    private func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = loopback(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private func loopback(port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }

    /// Start `nc -l` on `port` in a child and wait until it is LISTENing.
    private func startChildListener(port: Int) throws -> pid_t {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        proc.arguments = ["-l", "127.0.0.1", "\(port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        listener = proc
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if tcpListenerPIDs(port: port).contains(proc.processIdentifier) { return proc.processIdentifier }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("nc never listened on \(port)")
        return proc.processIdentifier
    }

    /// Connect from this process; returns the client fd (caller closes).
    private func connectClient(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = loopback(port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0, "connect errno \(errno)")
        return fd
    }

    private func oldLookup(port: Int) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-ti", ":\(port)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }

    /// Control: the old lookup names this process when it is only a client.
    func testOldLookupIncludesTheClientProcess() throws {
        let port = try freePort()
        let child = try startChildListener(port: port)
        let client = connectClient(port: port)
        defer { close(client) }

        let pids = oldLookup(port: port)
        XCTAssertTrue(pids.contains(child))
        XCTAssertTrue(pids.contains(getpid()), "control: lsof -ti :port should match the client end")
    }

    /// The fix: only the listener, never the connected client (us).
    func testListenerLookupReturnsOnlyTheListener() throws {
        let port = try freePort()
        let child = try startChildListener(port: port)
        let client = connectClient(port: port)
        defer { close(client) }

        XCTAssertEqual(tcpListenerPIDs(port: port), [child])
    }

    /// Even if this process were the listener, it is never returned.
    func testListenerLookupNeverReturnsSelf() throws {
        let port = try freePort()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = loopback(port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        XCTAssertTrue(oldLookup(port: port).contains(getpid()), "control: lsof sees our listener")
        XCTAssertEqual(tcpListenerPIDs(port: port), [])
    }

    func testParseDropsSelfAndDuplicates() {
        XCTAssertEqual(parseLsofPIDs("12\n34\n12\n 56 \n\nx\n", excluding: 34), [12, 56])
    }

    /// The provenance handler records the sender, and the DispatchSource
    /// shutdown path (kqueue) still fires with the handler installed.
    func testSignalProvenanceRecordsSenderAlongsideDispatchSource() throws {
        SignalProvenance.install()

        let fired = expectation(description: "dispatch source fired")
        fired.assertForOverFulfill = false
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { fired.fulfill() }
        source.resume()
        defer { source.cancel() }

        // From another process: the record names that sender, not us.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/bin/kill")
        kill.arguments = ["-TERM", "\(getpid())"]
        try kill.run()
        kill.waitUntilExit()
        let sender = kill.processIdentifier

        wait(for: [fired], timeout: 5)
        let deadline = Date().addingTimeInterval(5)
        var record = SignalProvenance.lastRecord()
        while record?.senderPID != sender && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            record = SignalProvenance.lastRecord()
        }
        XCTAssertEqual(record?.signo, SIGTERM)
        XCTAssertEqual(record?.senderPID, sender)

        // From ourselves: described as this process.
        Darwin.kill(getpid(), SIGTERM)
        let selfDeadline = Date().addingTimeInterval(5)
        while SignalProvenance.lastRecord()?.senderPID != getpid() && Date() < selfDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let selfRecord = try XCTUnwrap(SignalProvenance.lastRecord())
        XCTAssertEqual(selfRecord.senderPID, getpid())
        XCTAssertTrue(SignalProvenance.describe(selfRecord).hasPrefix("SIGTERM from pid \(getpid()) (this Sonata)"))
    }
}
