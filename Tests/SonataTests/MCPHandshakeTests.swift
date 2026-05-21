import XCTest
@testable import Sonata

// Plan §9 test 1 — Initialize round-trip + tools/list.
//
// Exercises MCPSessionState.handle for the two JSON-RPC methods every
// Claude Code session calls before doing anything else. Covers the
// protocolVersion echo, the experimental claude/channel capability that
// the SSE notification path depends on, and the exact tool set we ship.

final class MCPHandshakeTests: XCTestCase {

    func testInitializeReturnsProtocolVersionAndChannelCapability() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "test-init", role: .worker)
        let raw = await state.handle(
            method: "initialize",
            id: 1,
            params: ["protocolVersion": "2025-03-26", "capabilities": [:]]
        )
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")

        let caps = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(caps["tools"], "tools capability must be present")
        let experimental = try XCTUnwrap(caps["experimental"] as? [String: Any])
        XCTAssertNotNil(
            experimental["claude/channel"],
            "experimental.claude/channel is load-bearing for SSE notifications (plan §3)"
        )

        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "sonata-bridge",
            "name stays 'sonata-bridge' so existing --dangerously-load-development-channels flags keep working")
    }

    func testToolsListExposesCoreToolsAndOmitsRemovedDMRegistry() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "test-tools", role: .worker)
        let raw = await state.handle(method: "tools/list", id: 2, params: [:])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        // The worker surface = MCPToolSchemas.all ∪ the ActionRegistry schemas
        // (see MCPSessionState.mergedToolSchemas), so it grows whenever a new
        // mem_task_*/worker_* tool lands. Pinning the exact set turned this
        // test into a perpetual red the moment the surface expanded, so assert
        // the load-bearing invariants instead: the core transport/identity
        // tools must be present...
        let required: Set<String> = [
            "complete_event", "fail_event",
            "sonar_dm_send", "sonar_dm_inbox", "sonar_dm_broadcast",
            "sonata_identify",
            "mem_task_list", "mem_task_get", "mem_task_create",
            "mem_task_watch", "mem_task_unwatch",
        ]
        XCTAssertTrue(required.isSubset(of: names),
            "worker tool surface is missing required tools: "
                + "\(required.subtracting(names).sorted())")

        // ...and Plan §4's removed DM registry must stay gone. If a future
        // patch adds sonar_dm_register/sonar_dm_unregister back, this catches it.
        let removed: Set<String> = ["sonar_dm_register", "sonar_dm_unregister"]
        XCTAssertTrue(removed.isDisjoint(with: names),
            "removed DM-registry tools reappeared: "
                + "\(removed.intersection(names).sorted())")
    }

    func testInitializeBeforeAnyCallStillReturnsDefaultProtocolVersion() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "test-init-empty", role: .worker)
        // No protocolVersion in params — should still return the default.
        let raw = await state.handle(method: "initialize", id: 3, params: [:])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
    }

    func testInvalidBearerTokenIsRejectedByRegistry() async {
        let h = try! MCPTestHarness.make()
        defer { h.teardown() }

        let (token, _) = await h.registerSession(sessionKey: "test-bearer", role: .worker)
        let goodCheck = await h.mcpRegistry.validateBearer(
            sessionKey: "test-bearer", suppliedToken: token)
        let badCheck = await h.mcpRegistry.validateBearer(
            sessionKey: "test-bearer", suppliedToken: "wrong-token")
        let nilCheck = await h.mcpRegistry.validateBearer(
            sessionKey: "test-bearer", suppliedToken: nil)
        let unknownSessionCheck = await h.mcpRegistry.validateBearer(
            sessionKey: "never-registered", suppliedToken: token)

        XCTAssertTrue(goodCheck)
        XCTAssertFalse(badCheck, "constant-time comparison must reject the wrong token")
        XCTAssertFalse(nilCheck, "missing bearer must be rejected, not treated as anonymous")
        XCTAssertFalse(unknownSessionCheck, "unknown session must reject any token")
    }

    // MARK: helpers

    private func parseJSON(_ raw: String?) throws -> [String: Any] {
        let unwrapped = try XCTUnwrap(raw, "session returned no response")
        let data = try XCTUnwrap(unwrapped.data(using: .utf8))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "response was not a JSON object"
        )
    }
}
