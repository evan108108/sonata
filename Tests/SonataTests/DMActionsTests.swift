import XCTest
import GRDB
@testable import Sonata

// Sonar DMs v0 — DMActions.routeInbound + HTTP endpoint handler tests.
// Plan §8.1.

final class DMActionsTests: XCTestCase {

    // MARK: in-memory DB harness

    /// Build a GRDB pool with the dm_messages schema applied so tests can
    /// exercise persistence + queries without writing to /Users/evan/.sonata.
    /// Uses a per-test temp file because GRDB's DatabasePool requires WAL,
    /// which is unavailable on `:memory:` databases.
    private func makeInMemoryDbPool() throws -> DatabasePool {
        let tmp = NSTemporaryDirectory() + "sonata-dm-test-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS dm_messages (
                    messageId        TEXT PRIMARY KEY,
                    targetSessionId  TEXT NOT NULL,
                    fromSessionId    TEXT,
                    fromPubkey       TEXT,
                    fromPeerId       TEXT,
                    body             TEXT NOT NULL,
                    context          TEXT,
                    metaJson         TEXT,
                    sentAtMs         INTEGER NOT NULL,
                    receivedAtMs     INTEGER NOT NULL,
                    deliveredAtMs    INTEGER,
                    deliveryStatus   TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS dm_messages_target_received
                    ON dm_messages(targetSessionId, receivedAtMs DESC)
            """)
            // Workers table — needed for the production heartbeat checker;
            // tests that exercise checkers usually inject their own.
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

    private func dmMessagesCount(_ pool: DatabasePool, target: String? = nil) throws -> Int {
        try pool.read { db -> Int in
            if let target {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM dm_messages WHERE targetSessionId = ?",
                    arguments: [target]
                ) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dm_messages") ?? 0
        }
    }

    // MARK: routeInbound

    func testRouteInboundPersistsBeforeEnqueue() async throws {
        let pool = try makeInMemoryDbPool()
        let reg = DMRegistry()
        reg.register(sessionId: "session-x", sessionLabel: nil, role: nil)

        let payload: [String: Any] = [
            "message_id": "abc123",
            "target_session_id": "session-x",
            "from_session_id": "sender-1",
            "from_peer": "peer-pub-hex",
            "question": "hello",
            "context": "ctx",
        ]
        await DMActions.routeInbound(payload: payload, dbPool: pool, registry: reg, nowFn: { 5_000 })

        // Persisted.
        XCTAssertEqual(try dmMessagesCount(pool, target: "session-x"), 1)
        // Enqueued.
        let queue = reg._peekQueue(sessionId: "session-x")
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue[0].messageId, "abc123")
        XCTAssertEqual(queue[0].fromPubkey, "peer-pub-hex")
        XCTAssertEqual(queue[0].fromSessionId, "sender-1")
        XCTAssertEqual(queue[0].body, "hello")
        XCTAssertEqual(queue[0].receivedAtMs, 5_000)
    }

    func testRouteInboundShortCircuitsWhenTargetMissing() async throws {
        let pool = try makeInMemoryDbPool()
        let reg = DMRegistry()
        reg.register(sessionId: "session-x", sessionLabel: nil, role: nil)
        // No target_session_id → routeInbound bails (nothing happens).
        await DMActions.routeInbound(payload: ["question": "hello"], dbPool: pool, registry: reg)
        XCTAssertEqual(try dmMessagesCount(pool), 0)
        XCTAssertEqual(reg._peekQueue(sessionId: "session-x").count, 0)
    }

    func testRouteInboundUnregisteredTargetPersistsButDoesntEnqueue() async throws {
        let pool = try makeInMemoryDbPool()
        let reg = DMRegistry()
        // No registration for session-x.

        let payload: [String: Any] = [
            "message_id": "msg-99",
            "target_session_id": "session-x",
            "from_peer": "peer-pub",
            "question": "hello",
        ]
        await DMActions.routeInbound(payload: payload, dbPool: pool, registry: reg, nowFn: { 7_000 })

        // Row persisted for backfill.
        XCTAssertEqual(try dmMessagesCount(pool, target: "session-x"), 1)
        // Not enqueued.
        XCTAssertFalse(reg.has("session-x"))
        XCTAssertEqual(reg._peekQueue(sessionId: "session-x").count, 0)
    }

    func testRouteInboundIsIdempotentOnMessageId() async throws {
        let pool = try makeInMemoryDbPool()
        let reg = DMRegistry()
        reg.register(sessionId: "session-x", sessionLabel: nil, role: nil)

        let payload: [String: Any] = [
            "message_id": "same",
            "target_session_id": "session-x",
            "from_peer": "p",
            "question": "h",
        ]
        await DMActions.routeInbound(payload: payload, dbPool: pool, registry: reg)
        await DMActions.routeInbound(payload: payload, dbPool: pool, registry: reg)

        // dm_messages INSERT OR IGNORE keeps a single row.
        XCTAssertEqual(try dmMessagesCount(pool, target: "session-x"), 1)
        // Registry LRU drops the second enqueue.
        XCTAssertEqual(reg._peekQueue(sessionId: "session-x").count, 1)
    }

    // MARK: dm_register handler — security A.1

    func testDmRegisterRejectsSessionIdWithoutHeartbeat() async throws {
        let pool = try makeInMemoryDbPool()
        let action = dmActions.first { $0.name == "dm_register" }!

        // No worker row + no ExternalBridgeRegistry entry → reject.
        let ctx = ActionContext(
            params: ActionParams(["sessionId": "ghost-no-heartbeat"]),
            dbPool: pool
        )
        do {
            _ = try await action.handler(ctx)
            XCTFail("expected ActionError.custom")
        } catch let error as ActionError {
            switch error {
            case .custom(let msg, let status):
                XCTAssertTrue(msg.contains("bad_session_id"))
                XCTAssertEqual(status, .unprocessableContent)
            default:
                XCTFail("wrong error case: \(error)")
            }
        }
    }

    func testDmRegisterAcceptsSessionWithFreshWorkerHeartbeat() async throws {
        let pool = try makeInMemoryDbPool()
        // Seed a worker row with a fresh heartbeat.
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO workers (id, workerId, sessionLabel, sessionId, lastHeartbeat, registeredAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["wid-1", "wid-1", "scheduler-3", "fresh-session", nowMs(), nowMs()]
            )
        }
        let action = dmActions.first { $0.name == "dm_register" }!
        let ctx = ActionContext(
            params: ActionParams([
                "sessionId": "fresh-session",
                "sessionLabel": "scheduler-3",
                "role": "worker",
            ]),
            dbPool: pool
        )
        let response = try await action.handler(ctx)

        // Encode → decode round trip.
        let data = try JSONEncoder().encode(EncodableShim(value: response))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["sessionId"] as? String, "fresh-session")
        XCTAssertEqual(json?["ok"] as? Bool, true)

        // Cleanup: unregister so subsequent tests see a clean state.
        DMRegistry.shared.unregister(sessionId: "fresh-session")
    }

    func testDmRegisterRejectsInvalidSessionIdRegex() async throws {
        let pool = try makeInMemoryDbPool()
        let action = dmActions.first { $0.name == "dm_register" }!
        let ctx = ActionContext(
            params: ActionParams(["sessionId": "has spaces!"]),
            dbPool: pool
        )
        do {
            _ = try await action.handler(ctx)
            XCTFail("expected reject")
        } catch let error as ActionError {
            if case .custom(let msg, let status) = error {
                XCTAssertTrue(msg.contains("bad_session_id"))
                XCTAssertEqual(status, .unprocessableContent)
            } else {
                XCTFail("wrong case")
            }
        }
    }

    // MARK: dm_send handler — error matrix

    func testDmSendUnknownLocalTargetReturns404() async throws {
        let pool = try makeInMemoryDbPool()
        let action = dmActions.first { $0.name == "dm_send" }!
        let ctx = ActionContext(
            params: ActionParams([
                "targetSessionId": "nobody",
                "fromSessionId": "alice",
                "body": "hello",
            ]),
            dbPool: pool
        )
        do {
            _ = try await action.handler(ctx)
            XCTFail("expected 404")
        } catch let error as ActionError {
            if case .custom(let msg, let status) = error {
                XCTAssertTrue(msg.contains("target_session_unknown"))
                XCTAssertEqual(status, .notFound)
            } else {
                XCTFail("wrong case: \(error)")
            }
        }
    }

    func testDmSendEmptyBodyReturns422() async throws {
        let pool = try makeInMemoryDbPool()
        let action = dmActions.first { $0.name == "dm_send" }!
        let ctx = ActionContext(
            params: ActionParams([
                "targetSessionId": "x",
                "fromSessionId": "alice",
                "body": "",
            ]),
            dbPool: pool
        )
        do {
            _ = try await action.handler(ctx)
            XCTFail("expected 422")
        } catch let error as ActionError {
            // Empty body trips the body_empty check (or missing-required, since
            // ctx.params.require throws on empty too — both are 4xx and acceptable).
            switch error {
            case .custom(let msg, let status):
                XCTAssertEqual(status, .unprocessableContent)
                XCTAssertTrue(msg.contains("body_empty") || msg.contains("Missing"))
            case .missingParam:
                break
            default:
                XCTFail("wrong case: \(error)")
            }
        }
    }

    func testDmSendBodyTooLargeReturns422() async throws {
        let pool = try makeInMemoryDbPool()
        let action = dmActions.first { $0.name == "dm_send" }!
        let bigBody = String(repeating: "x", count: DMLimits.bodyMaxBytes + 1)
        let ctx = ActionContext(
            params: ActionParams([
                "targetSessionId": "x",
                "fromSessionId": "alice",
                "body": bigBody,
            ]),
            dbPool: pool
        )
        do {
            _ = try await action.handler(ctx)
            XCTFail("expected 422")
        } catch let error as ActionError {
            if case .custom(let msg, let status) = error {
                XCTAssertTrue(msg.contains("body_too_large"))
                XCTAssertEqual(status, .unprocessableContent)
            } else {
                XCTFail("wrong case")
            }
        }
    }

    func testDmSendLazyOptimisticOnRecentInbox() async throws {
        let pool = try makeInMemoryDbPool()
        // Seed a recent dm_messages row for target-y (within 24h).
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dm_messages (
                        messageId, targetSessionId, fromSessionId, fromPubkey, fromPeerId,
                        body, context, metaJson, sentAtMs, receivedAtMs, deliveryStatus
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "seed-1", "target-y", nil, nil, nil,
                    "earlier", nil, nil, nowMs(), nowMs(), "queued",
                ]
            )
        }
        let action = dmActions.first { $0.name == "dm_send" }!
        let ctx = ActionContext(
            params: ActionParams([
                "targetSessionId": "target-y",
                "fromSessionId": "alice",
                "body": "follow-up",
            ]),
            dbPool: pool
        )
        let response = try await action.handler(ctx)
        let data = try JSONEncoder().encode(EncodableShim(value: response))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["deliveryStatus"] as? String, "queued_unregistered")
        // Persisted as second row.
        XCTAssertEqual(try dmMessagesCount(pool, target: "target-y"), 2)
    }

    // MARK: dm_inbox handler

    func testDmInboxReturnsRowsOrderedAsc() async throws {
        let pool = try makeInMemoryDbPool()
        try await pool.write { db in
            for i in 0..<3 {
                try db.execute(
                    sql: """
                        INSERT INTO dm_messages (messageId, targetSessionId, body, sentAtMs, receivedAtMs, deliveryStatus)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: ["m\(i)", "t1", "body-\(i)", 100 + i, 1000 + i, "queued"]
                )
            }
        }
        let action = dmActions.first { $0.name == "dm_inbox" }!
        let ctx = ActionContext(
            params: ActionParams(["sessionId": "t1", "since": 0, "limit": 50]),
            dbPool: pool
        )
        let response = try await action.handler(ctx)
        let data = try JSONEncoder().encode(EncodableShim(value: response))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["messageId"] as? String, "m0")
        XCTAssertEqual(messages[2]["messageId"] as? String, "m2")
    }

    // MARK: dm_unregister is idempotent

    func testDmUnregisterIdempotent() async throws {
        let pool = try makeInMemoryDbPool()
        let action = dmActions.first { $0.name == "dm_unregister" }!
        let ctx = ActionContext(
            params: ActionParams(["sessionId": "never-registered"]),
            dbPool: pool
        )
        // Should not throw.
        _ = try await action.handler(ctx)
    }
}

// Type-erased Encodable shim so XCTest can JSONEncode `any Encodable` results
// without a concrete type at the call site.
private struct EncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
