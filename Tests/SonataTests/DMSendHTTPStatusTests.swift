import XCTest
import GRDB
import Hummingbird
import HummingbirdTesting
@testable import Sonata

// POST /api/dm/send status codes (learning 417af3a3): an undelivered DM used to
// return HTTP 200, so `curl -f` callers read not_found as success. The route
// now returns 404 for not_found (409 for not_live) with the same JSON body,
// and the MCP tool still returns a normal, non-error result.

final class DMSendHTTPStatusTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-dm-http-test-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS workers (
                    id            TEXT PRIMARY KEY,
                    workerId      TEXT NOT NULL UNIQUE,
                    sessionLabel  TEXT NOT NULL DEFAULT '',
                    sessionId     TEXT,
                    status        TEXT NOT NULL DEFAULT 'idle',
                    capabilities  TEXT NOT NULL DEFAULT '[]',
                    lastHeartbeat INTEGER NOT NULL,
                    registeredAt  INTEGER NOT NULL
                )
            """)
        }
        return pool
    }

    private func makeRegistry() -> ActionRegistry {
        let registry = ActionRegistry()
        registry.register(dmActions)
        return registry
    }

    func testHTTPDmSendUnknownTargetIs404WithNotFoundBody() async throws {
        let pool = try makePool()
        let registry = makeRegistry()
        let router = Router()
        registry.mountHTTP(on: router, dbPool: pool)
        let app = Application(router: router)

        let payload = #"{"target":"no-such-target-http-test","fromSessionId":"alice","body":"hello"}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/dm/send",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: payload)
            ) { response in
                XCTAssertEqual(response.status, .notFound,
                    "an undelivered DM must not be a 2xx, or curl -f reads it as success")
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                XCTAssertEqual(json?["status"] as? String, "not_found")
                XCTAssertNotNil(json?["reason"] as? String, "the body keeps its reason on a 404")
            }
        }
    }

    func testMCPDmSendUnknownTargetStaysNormalResult() async throws {
        let pool = try makePool()
        let registry = makeRegistry()
        let (success, output) = await registry.executeMCPTool(
            name: "dm_send",
            args: ["target": "no-such-target-mcp-test", "fromSessionId": "alice", "body": "hello"],
            dbPool: pool
        )
        XCTAssertTrue(success, "MCP dm_send must return a normal result carrying status, not an error")
        let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "not_found")
    }

    func testDmSendHTTPStatusMapping() {
        func status(_ s: String) -> HTTPResponse.Status {
            httpStatus(for: DMSendHTTPResult(response: DMSendResponse(status: s, messageId: nil, reason: nil)))
        }
        XCTAssertEqual(status("sent"), .ok)
        XCTAssertEqual(status("not_found"), .notFound)
        XCTAssertEqual(status("not_live"), .conflict)
    }

    // MARK: dashboard copy

    func testDashboardCopyOnlySaysSentForSent() {
        let sent = Data(#"{"status":"sent","messageId":"m1"}"#.utf8)
        XCTAssertEqual(dmSendResultText(target: "Scout", httpCode: 200, data: sent), "Sent to Scout — sent")

        let missing = Data(#"{"status":"not_found","reason":"no_such_target"}"#.utf8)
        XCTAssertEqual(dmSendResultText(target: "Scout", httpCode: 404, data: missing),
                       "Not delivered to Scout — not_found (no_such_target)")

        let offline = Data(#"{"status":"not_live","reason":"no_live_connection"}"#.utf8)
        XCTAssertEqual(dmSendResultText(target: "w1", httpCode: 409, data: offline),
                       "Not delivered to w1 — not_live (no_live_connection)")

        let error = Data(#"{"error":"body_empty"}"#.utf8)
        XCTAssertEqual(dmSendResultText(target: "w1", httpCode: 422, data: error),
                       #"Failed (HTTP 422) — {"error":"body_empty"}"#)
    }
}
