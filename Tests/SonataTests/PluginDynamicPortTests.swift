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

    func testProcArgs2EnvironmentSkipsExecPathAndArgv() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes += $0 }
        bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("/x/server.js".utf8) + [0]
        bytes += Array("PORT=4100".utf8) + [0]
        bytes += Array("SONATA_PLUGIN_DATA_DIR=/Users/x/.sonata/plugins/prstar".utf8) + [0]
        bytes += Array("EMPTY=".utf8) + [0, 0]
        bytes += Array("ptr_munge=ignored".utf8) + [0]
        let env = parseProcArgs2Environment(bytes)
        XCTAssertEqual(env?["PORT"], "4100")
        XCTAssertEqual(env?["SONATA_PLUGIN_DATA_DIR"], "/Users/x/.sonata/plugins/prstar")
        XCTAssertEqual(env?["EMPTY"], "")
        XCTAssertNil(env?["ptr_munge"])
        XCTAssertNil(env?["node"])
    }

    func testProcArgs2EnvironmentRejectsTruncatedArgv() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/bin/x".utf8) + [0] + Array("x".utf8) + [0]
        XCTAssertNil(parseProcArgs2Environment(bytes))
        XCTAssertNil(parseProcArgs2Environment([1, 0]))
    }

    func testSameDirectoryIgnoresTrailingSlash() {
        XCTAssertTrue(isSameDirectory("/Users/x/.sonata/plugins/prstar/", "/Users/x/.sonata/plugins/prstar"))
        XCTAssertFalse(isSameDirectory("/Users/x/.sonata/plugins/prstar-old", "/Users/x/.sonata/plugins/prstar"))
    }
    /// 10/29: prstar and lead-tracker run under Homebrew/nvm node, outside
    /// their plugin dirs. The env marker Sonata sets on spawn is what
    /// identifies them as the plugin's own stale processes.
    func testProcessBelongsToPluginByEnvMarker() {
        let plugin = "/Users/x/.sonata/plugins/prstar"
        let exes: [pid_t: String] = [
            1: "/Users/x/.sonata/plugins/sonar/erts-16.3.1/bin/beam.smp",
            2: "/opt/homebrew/Cellar/node/25.2.1/bin/node",
            3: "/opt/homebrew/Cellar/node/25.2.1/bin/node",
            4: "/opt/homebrew/Cellar/node/25.2.1/bin/node",
        ]
        let envs: [pid_t: [String: String]] = [
            2: ["SONATA_PLUGIN_DATA_DIR": plugin + "/"],
            3: ["SONATA_PLUGIN_DATA_DIR": "/Users/x/.sonata/plugins/lead-tracker"],
            4: ["PATH": "/usr/bin"],
        ]
        let belongs = { (pid: pid_t, path: String) in
            processBelongsToPlugin(pid, pluginPath: path, executable: { exes[$0] }, environment: { envs[$0] })
        }
        XCTAssertTrue(belongs(1, "/Users/x/.sonata/plugins/sonar"))   // release binary in its dir
        XCTAssertTrue(belongs(2, plugin))                             // node, marked for this plugin
        XCTAssertFalse(belongs(3, plugin))                            // node, another plugin's
        XCTAssertFalse(belongs(4, plugin))                            // node, unmarked
        XCTAssertFalse(belongs(5, plugin))                            // unreadable (root's nxd)
    }

    func testProcessEnvironmentReadsALiveProcess() {
        XCTAssertNotNil(processEnvironment(of: getpid())?["PATH"])
        XCTAssertNil(processEnvironment(of: 999_999))
    }
}
