import XCTest
@testable import Sonata

// Plan §9 test 1 — Initialize round-trip + tools/list.
//
// Exercises MCPHandshake.handle for the two JSON-RPC methods every
// Claude Code session calls before doing anything else. Covers the
// protocolVersion echo, the experimental claude/channel capability that
// the SSE notification path depends on, and the exact tool set we ship.
//
// The bearer-token test that used to live here (MCPSessionRegistry.
// validateBearer) was removed with the ecfb094 refactor — the current
// server model doesn't have a per-session bearer registry; auth lives
// at a different layer.

final class MCPHandshakeTests: XCTestCase {

    func testInitializeReturnsProtocolVersionAndChannelCapability() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let raw = await h.handle(
            sessionKey: "test-init", role: .worker,
            method: "initialize", id: 1,
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

        let raw = await h.handle(
            sessionKey: "test-tools", role: .worker,
            method: "tools/list", id: 2, params: [:])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        // The worker surface = MCPToolSchemas.all ∪ the ActionRegistry schemas,
        // so it grows whenever a new mem_task_*/worker_* tool lands. Pinning
        // the exact set turned this test into a perpetual red the moment the
        // surface expanded, so assert the load-bearing invariants instead:
        // the core transport/identity tools must be present...
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

        // ...and the dead DM registry surface must stay gone. dm_send always
        // queues durably; targets receive via live SSE push or dm_inbox poll.
        // No registration step exists; if a regression reintroduces any of
        // these, workers will hallucinate a registration model again.
        let removed: Set<String> = [
            "sonar_dm_register", "sonar_dm_unregister",
            "dm_register", "dm_unregister", "dm_poll",
        ]
        XCTAssertTrue(removed.isDisjoint(with: names),
            "removed DM-registry tools reappeared: "
                + "\(removed.intersection(names).sorted())")
    }

    func testInitializeBeforeAnyCallStillReturnsDefaultProtocolVersion() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        // No protocolVersion in params — should still return the default.
        let raw = await h.handle(
            sessionKey: "test-init-empty", role: .worker,
            method: "initialize", id: 3, params: [:])
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
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
