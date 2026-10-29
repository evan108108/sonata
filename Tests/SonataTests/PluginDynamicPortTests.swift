import XCTest
import Darwin
@testable import Sonata

/// 10/29: NoMachine's nxd took *:4000 as root at boot, sonar died with
/// eaddrinuse, and both Sonatas kept calling a hardcoded 127.0.0.1:4000.
/// A dynamic-port plugin now binds a free port in its manifest range and
/// callers resolve it through PluginEndpointRegistry.
final class PluginDynamicPortTests: XCTestCase {

    private var held: [Int32] = []

    override func tearDown() {
        held.forEach { close($0) }
        held = []
        PluginEndpointRegistry.remove("sonar")
        super.tearDown()
    }

    /// Binds and listens on an ephemeral INADDR_ANY port, kept open until tearDown.
    private func holdPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        held.append(fd)
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    // MARK: - Port probing and picking

    func testHeldPortIsNotFree() {
        let port = holdPort()
        XCTAssertFalse(tcpPortIsFree(port))
        close(held.removeLast())
        XCTAssertTrue(tcpPortIsFree(port))
    }

    func testPickPrefersTheStickyPortWhenFree() {
        XCTAssertEqual(pickPluginPort(preferred: 4005, range: 4001...4020, isFree: { _ in true }), 4005)
    }

    func testPickIgnoresAPreferredPortOutsideTheRange() {
        // A row still carrying the legacy 4000 lands on the range's first free port.
        XCTAssertEqual(pickPluginPort(preferred: 4000, range: 4001...4020, isFree: { _ in true }), 4001)
        XCTAssertEqual(pickPluginPort(preferred: nil, range: 4001...4020, isFree: { _ in true }), 4001)
    }

    func testPickSkipsHeldPorts() {
        let busy: Set<Int> = [4001, 4002, 4005]
        XCTAssertEqual(pickPluginPort(preferred: 4005, range: 4001...4020, isFree: { !busy.contains($0) }), 4003)
    }

    func testPickReturnsNilWhenTheWholeRangeIsHeld() {
        XCTAssertNil(pickPluginPort(preferred: 4001, range: 4001...4003, isFree: { _ in false }))
    }

    func testPickWalksPastARealListener() {
        let port = holdPort()
        let picked = pickPluginPort(preferred: port, range: port...(port + 10))
        XCTAssertNotNil(picked)
        XCTAssertNotEqual(picked, port)
    }

    // MARK: - Manifest

    private func manifest(_ extra: String) throws -> PluginManifest {
        let json = #"{"name":"sonar","version":"0.2.0","port":4001,"start_command":"bin/sonar start""# + extra + "}"
        return try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    func testDynamicPortRangeFromManifest() throws {
        XCTAssertEqual(try manifest(#","port_policy":"dynamic","port_range":[4001,4020]"#).dynamicPortRange, 4001...4020)
    }

    func testFixedPortManifestHasNoRange() throws {
        XCTAssertNil(try manifest("").dynamicPortRange)
        // A range without the policy is ignored: opting in is explicit (prstar must stay on 4100).
        XCTAssertNil(try manifest(#","port_range":[4001,4020]"#).dynamicPortRange)
    }

    func testMalformedRangeIsIgnored() throws {
        XCTAssertNil(try manifest(#","port_policy":"dynamic","port_range":[4020,4001]"#).dynamicPortRange)
        XCTAssertNil(try manifest(#","port_policy":"dynamic","port_range":[4001]"#).dynamicPortRange)
        XCTAssertNil(try manifest(#","port_policy":"dynamic","port_range":[0,70000]"#).dynamicPortRange)
    }

    // MARK: - Registry and SonarPluginEndpoint

    func testSonarEndpointFallsBackToTheLegacyPortUntilPublished() {
        PluginEndpointRegistry.remove("sonar")
        XCTAssertEqual(SonarPluginEndpoint.base, "http://127.0.0.1:4000")
        XCTAssertEqual(SonarPluginEndpoint.peers.absoluteString, "http://127.0.0.1:4000/api/peers")
    }

    func testSonarEndpointFollowsThePublishedPort() {
        PluginEndpointRegistry.publish("sonar", baseURL: "http://127.0.0.1:4003")
        XCTAssertEqual(SonarPluginEndpoint.peers.absoluteString, "http://127.0.0.1:4003/api/peers")
        XCTAssertEqual(SonarPluginEndpoint.cardJSON.absoluteString, "http://127.0.0.1:4003/.well-known/sonar/card.json")
        XCTAssertEqual(SonarPluginEndpoint.messagesSend.absoluteString, "http://127.0.0.1:4003/api/messages/send")
        XCTAssertEqual(SonarPluginEndpoint.messagesAckForward.absoluteString, "http://127.0.0.1:4003/api/messages/ack_forward")

        PluginEndpointRegistry.remove("sonar")
        XCTAssertEqual(SonarPluginEndpoint.base, SonarPluginEndpoint.fallbackBase)
    }

    // MARK: - Identity and ownership checks

    func testHealthIdentityMustNameThePlugin() {
        XCTAssertTrue(pluginIdentityMatches(healthBody: Data(#"{"status":"ok","app":"sonar","port":4001}"#.utf8), name: "sonar"))
        XCTAssertFalse(pluginIdentityMatches(healthBody: Data(#"{"status":"ok","app":"prstar"}"#.utf8), name: "sonar"))
        XCTAssertFalse(pluginIdentityMatches(healthBody: Data(#"{"status":"ok"}"#.utf8), name: "sonar"))
        // NoMachine answers :4000 with an empty reply.
        XCTAssertFalse(pluginIdentityMatches(healthBody: Data(), name: "sonar"))
    }

    func testPathInsideIsNotFooledByASiblingPrefix() {
        XCTAssertTrue(isPath("/Users/x/.sonata/plugins/sonar/erts-16.3.1/bin/beam.smp", inside: "/Users/x/.sonata/plugins/sonar"))
        XCTAssertTrue(isPath("/Users/x/.sonata/plugins/sonar/bin/sonar", inside: "/Users/x/.sonata/plugins/sonar/"))
        XCTAssertFalse(isPath("/Users/x/.sonata/plugins/sonar-old/bin/sonar", inside: "/Users/x/.sonata/plugins/sonar"))
        XCTAssertFalse(isPath("/Applications/NoMachine.app/Contents/Frameworks/bin/nxd", inside: "/Users/x/.sonata/plugins/sonar"))
    }

    func testExecutablePathOfThisProcess() {
        let path = executablePath(of: getpid())
        XCTAssertNotNil(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path ?? ""))
    }

    func testExecutablePathOfAMissingPidIsNil() {
        XCTAssertNil(executablePath(of: 999_999))
    }
}
