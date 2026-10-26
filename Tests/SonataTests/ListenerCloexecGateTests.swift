import XCTest
import Darwin
@testable import Sonata

/// 2026-10-25 deploy-local outage (memory 9c94ba95). Sonata resumed its
/// interactive sessions about a second before a 500ms-delayed sweep set
/// FD_CLOEXEC on the :3211 listener. Three forkpty children inherited it, so
/// when the HTTP watchdog restarted the server every rebind hit EADDRINUSE
/// and :3211 stayed down for the fleet.
///
/// The fix: every forkpty spawn waits on `ListenerCloexecGate`, which the
/// server opens only after `sealListenerAndOpenGate` has flagged the new
/// listener. These tests run that ordering against a real listen socket.
///
/// The child comes from raw posix_spawn WITHOUT POSIX_SPAWN_CLOEXEC_DEFAULT,
/// the faithful model of SwiftTerm's forkpty. Foundation's `Process` closes
/// every descriptor on Darwin, so a Process-based version passes against the
/// unfixed code (the 7/19 flock test found that out the hard way).
final class ListenerCloexecGateTests: XCTestCase {

    // MARK: - The outage, end to end

    /// The restored-session shape: the spawn is requested while the listener
    /// is bound and not yet flagged, then the server seals it. The child must
    /// not keep the port, so a rebind after the parent closes its copy works.
    func testSpawnRequestedBeforeSealDoesNotInheritListener() throws {
        let (listener, port) = try makeListener()
        let delivery = DispatchQueue(label: "gate-test-delivery")
        let gate = ListenerCloexecGate(open: false, deliveryQueue: delivery)

        var childPid: pid_t = 0
        let spawned = expectation(description: "gated spawn ran")
        gate.afterOpen {
            childPid = Self.spawnInheritingChild()
            spawned.fulfill()
        }
        XCTAssertEqual(childPid, 0, "a closed gate must not run the spawn yet")

        let sealed = expectation(description: "sealed")
        Task {
            await sealListenerAndOpenGate(port: port, gate: gate)
            sealed.fulfill()
        }
        wait(for: [sealed, spawned], timeout: 5)
        XCTAssertGreaterThan(childPid, 0, "failed to spawn the inheriting child")
        addTeardownBlock { Self.reap(childPid) }

        // The parent's server tears down, as in the outage.
        close(listener)

        XCTAssertTrue(Self.canBind(port: port),
                      "a child forked through the gate still holds :\(port), so a rebind would hit EADDRINUSE")
    }

    /// Control row: the same child forked straight away, with no gate, DOES
    /// pin the port. If this ever passes the bind, the harness can't see
    /// inheritance and the test above certifies nothing.
    func testUngatedSpawnBeforeSealPinsThePort() throws {
        let (listener, port) = try makeListener()
        let childPid = Self.spawnInheritingChild()
        XCTAssertGreaterThan(childPid, 0, "failed to spawn the inheriting child")
        addTeardownBlock { Self.reap(childPid) }

        setCloseOnExecOnListenSockets(port: port, log: false)  // too late for this child
        close(listener)

        XCTAssertFalse(Self.canBind(port: port),
                       "control: an inheriting child forked before the seal should keep the port in LISTEN")
    }

    // MARK: - Gate semantics

    func testOpenGateRunsInline() {
        let gate = ListenerCloexecGate(open: true, deliveryQueue: DispatchQueue(label: "unused"))
        var ran = false
        gate.afterOpen { ran = true }
        XCTAssertTrue(ran, "an open gate runs the spawn synchronously, as before the gate existed")
    }

    func testQueuedSpawnsRunInOrderWhenOpened() {
        let delivery = DispatchQueue(label: "gate-test-order")
        let gate = ListenerCloexecGate(open: false, deliveryQueue: delivery)
        var order: [Int] = []
        let done = expectation(description: "all ran")
        done.expectedFulfillmentCount = 3
        for i in 1...3 {
            gate.afterOpen {
                order.append(i)
                done.fulfill()
            }
        }
        XCTAssertTrue(order.isEmpty)
        gate.open(reason: "test")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testClosedAgainQueuesUntilReopened() {
        let delivery = DispatchQueue(label: "gate-test-reclose")
        let gate = ListenerCloexecGate(open: true, deliveryQueue: delivery)
        gate.close(reason: "restart")
        var ran = false
        gate.afterOpen { ran = true }
        XCTAssertFalse(ran, "a restart must hold spawns until the new listener is sealed")
        let done = expectation(description: "ran after reopen")
        gate.afterOpen { done.fulfill() }
        gate.open(reason: "resealed")
        wait(for: [done], timeout: 2)
        XCTAssertTrue(ran)
    }

    /// No listener at all: the gate still opens after the timeout instead of
    /// stranding every session and worker.
    func testSealOpensGateWhenNoListenerExists() {
        let gate = ListenerCloexecGate(open: false, deliveryQueue: DispatchQueue(label: "unused"))
        let done = expectation(description: "sealed")
        Task {
            await sealListenerAndOpenGate(port: 1, gate: gate, timeout: .milliseconds(100))
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(gate.isOpen)
    }

    func testSealFlagsTheListener() throws {
        let (listener, port) = try makeListener()
        defer { close(listener) }
        XCTAssertEqual(fcntl(listener, F_GETFD) & FD_CLOEXEC, 0, "precondition: a fresh socket is not close-on-exec")
        let gate = ListenerCloexecGate(open: false, deliveryQueue: DispatchQueue(label: "unused"))
        let done = expectation(description: "sealed")
        Task {
            await sealListenerAndOpenGate(port: port, gate: gate)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertNotEqual(fcntl(listener, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertTrue(gate.isOpen)
    }

    // MARK: - EADDRINUSE holder logging

    func testParseLsofListenHolders() {
        let out = "p56039\ncclaude\np55996\ncSonata\n"
        let holders = parseLsofListenHolders(out)
        XCTAssertEqual(holders.map(\.pid), [56039, 55996])
        XCTAssertEqual(holders.map(\.command), ["claude", "Sonata"])
        XCTAssertTrue(parseLsofListenHolders("").isEmpty)
    }

    func testDescribeListenPortHoldersNamesThisProcess() throws {
        let (listener, port) = try makeListener()
        defer { close(listener) }
        let line = describeListenPortHolders(port: port)
        XCTAssertTrue(line.contains("\(getpid())"), "lsof should name this test process as the holder: \(line)")
    }

    // MARK: - Helpers

    /// A plain TCP listener on an ephemeral 127.0.0.1 port, created without
    /// FD_CLOEXEC, like NIO's acceptor socket on Darwin.
    private func makeListener() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, Int(UInt16(bigEndian: got.sin_port)))
    }

    /// posix_spawn with default attributes: descriptors without FD_CLOEXEC
    /// survive into the child, exactly as with forkpty.
    private static func spawnInheritingChild() -> pid_t {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        return posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0 ? pid : -1
    }

    private static func reap(_ pid: pid_t) {
        guard pid > 0 else { return }
        // SIGKILL: a child spawned from a GCD thread inherits its blocked
        // signal mask, so SIGTERM would wait out the full sleep.
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// Whether a fresh listener can take `port`. SO_REUSEADDR matches the
    /// server, so TIME_WAIT leftovers don't count, only a live LISTEN holder.
    private static func canBind(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return bound == 0 && listen(fd, 1) == 0
    }
}
