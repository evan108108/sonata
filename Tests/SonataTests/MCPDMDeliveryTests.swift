import XCTest
import GRDB
@testable import Sonata

// Plan §9 — sonar_dm_send local-delivery path + G3 DMEnvelope alignment.
//
// Exercises the path that replaces the deleted DMRegistry (plan §4 "the DM
// registry goes away entirely"): sonar_dm_send for a local target persists
// to dm_messages and calls MCPSessionRegistry.deliverDM. The SSE frame
// envelope is the contract every reader's prompt expects to parse — if a
// field name on either side drifts, the worker can't reply.
//
// Federated DMs (peer_id present) still route through the legacy dm_send
// action; covered by Tests/federated/sonar-dm.test.ts and DMActionsTests.

final class MCPDMDeliveryTests: XCTestCase {

    func testLocalDMDeliversInlineWhenReceiverHasSSE() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        // Sender + receiver both registered.
        let (_, senderState) = await h.registerSession(sessionKey: "dm-sndr", role: .worker)
        let (_, receiverState) = await h.registerSession(sessionKey: "dm-rcvr", role: .worker)
        let receiverWriter = MCPSSEWriter()
        await receiverState.attachSSE(receiverWriter)

        let raw = await senderState.handle(
            method: "tools/call",
            id: 200,
            params: [
                "name": "sonar_dm_send",
                "arguments": [
                    "target_session_id": "dm-rcvr",
                    "body": "hello-dm-local",
                    "context": "test-ctx",
                ],
            ]
        )
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "sonar_dm_send should succeed; got \(result)")

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let resultText = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(resultText.contains("\"delivery_status\":\"delivered\""),
            "local target with attached SSE must deliver inline; got \(resultText)")

        // SSE frame at receiver — G3 envelope alignment check.
        let frames = await MCPSSEFrameCollector.collect(
            from: receiverWriter, timeout: 2.0,
            until: { $0.contains("hello-dm-local") }
        )
        let frame = try XCTUnwrap(
            frames.first(where: { $0.contains("hello-dm-local") }),
            "expected DM body in SSE; got \(frames)"
        )
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try XCTUnwrap(frame.data(using: .utf8))) as? [String: Any])
        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        let meta = try XCTUnwrap(params["meta"] as? [String: Any])
        XCTAssertEqual(meta["event_type"] as? String, "sonar_dm")
        XCTAssertEqual(meta["from_session_id"] as? String, "dm-sndr")
        XCTAssertEqual(meta["target_session_id"] as? String, "dm-rcvr")
        XCTAssertEqual(meta["context"] as? String, "test-ctx")
        XCTAssertNotNil(meta["message_id"] as? String)
        XCTAssertNotNil(meta["sent_at_ms"] as? String)

        // dm_messages row persisted with delivered status.
        let status = try await h.dbPool.read { db in
            try String.fetchOne(db, sql: """
                SELECT deliveryStatus FROM dm_messages
                WHERE fromSessionId = ? AND targetSessionId = ?
                """, arguments: ["dm-sndr", "dm-rcvr"])
        }
        XCTAssertEqual(status, "delivered")
    }

    func testLocalDMQueuesWhenReceiverHasNoSSE() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, senderState) = await h.registerSession(sessionKey: "dm-sndr2", role: .worker)
        // Receiver registered (has token + state) but no SSE writer attached.
        _ = await h.registerSession(sessionKey: "dm-rcvr2", role: .worker)

        let raw = await senderState.handle(
            method: "tools/call",
            id: 201,
            params: [
                "name": "sonar_dm_send",
                "arguments": [
                    "target_session_id": "dm-rcvr2",
                    "body": "queued-dm",
                ],
            ]
        )
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let resultText = try XCTUnwrap(
            (result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(resultText.contains("\"delivery_status\":\"queued\""),
            "no SSE means queued; got \(resultText)")

        // Row still persisted so sonar_dm_inbox can backfill it later.
        let count = try await h.dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM dm_messages
                WHERE targetSessionId = ?
                """, arguments: ["dm-rcvr2"]) ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testLocalDMRejectsEmptyBody() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "dm-empty", role: .worker)
        let raw = await state.handle(
            method: "tools/call",
            id: 202,
            params: [
                "name": "sonar_dm_send",
                "arguments": ["target_session_id": "dm-rcvr", "body": ""],
            ]
        )
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
            "empty body must error so the worker doesn't silently send blanks")
    }

    func testLocalDMRejectsInvalidTarget() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }

        let (_, state) = await h.registerSession(sessionKey: "dm-badtgt", role: .worker)
        let raw = await state.handle(
            method: "tools/call",
            id: 203,
            params: [
                "name": "sonar_dm_send",
                "arguments": [
                    "target_session_id": "has spaces and !!! bad chars",
                    "body": "x",
                ],
            ]
        )
        let response = try parseJSON(raw)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
            "MCPSessionKey regex must reject non-conforming target_session_id")
    }

    private func parseJSON(_ raw: String?) throws -> [String: Any] {
        let unwrapped = try XCTUnwrap(raw)
        let data = try XCTUnwrap(unwrapped.data(using: .utf8))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
