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

    // The three routeInbound tests that used to live here targeted the
    // static `DMActions.routeInbound` API which was removed. The equivalent
    // inbound routing now lives at `DMActionsInbound.routePeerInbound` and
    // takes a different payload shape and no nowFn injection. If we want
    // to reinstate coverage there, port the tests against the new API
    // rather than resurrecting the old one. Left as a deliberate gap
    // rather than a stale test that lies about what it exercises.

    // MARK: dm_send handler — error matrix
    //
    // The dm_send response shape changed with ecfb094 to fire-and-observe:
    // { status: "sent" | "not_live" | "not_found", messageId, reason }.
    // The old "queued" status and the "appends to inbox" test are gone —
    // there's no inbox to append to and no queue to observe.

    func testDmSendUnknownTargetReturnsNotFound() async throws {
        let pool = try makeInMemoryDbPool()
        let action = dmActions.first { $0.name == "dm_send" }!
        let ctx = ActionContext(
            params: ActionParams([
                "target": "nobody",
                "fromSessionId": "alice",
                "body": "hello",
            ]),
            dbPool: pool
        )
        let response = try await action.handler(ctx)
        let data = try JSONEncoder().encode(EncodableShim(value: response))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "not_found",
            "unknown-target sends must resolve to status=not_found, not throw or queue; got \(json ?? [:])")
    }

    func testDmSendEmptyBodyReturns422() async throws {
        let pool = try makeInMemoryDbPool()
        let action = dmActions.first { $0.name == "dm_send" }!
        let ctx = ActionContext(
            params: ActionParams([
                "target": "x",
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
        // DMLimits was removed; the current cap is inlined in DMActions
        // as 256 KB (see the ≤ 256 KB checks in dm_send/dm_reply/dm_broadcast).
        let bigBody = String(repeating: "x", count: 256 * 1024 + 1)
        let ctx = ActionContext(
            params: ActionParams([
                "target": "x",
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

    // testDmSendAppendsToExistingInbox was removed with the fire-and-observe
    // model — there is no inbox to append to, and outbound sends now flow
    // through DMAudit rather than dm_messages when the target is unresolved.
    // The "did this send get persisted for backfill" concept doesn't exist
    // in the new model, so there's no equivalent test to port to.

    // dm_inbox handler was deleted with ecfb094 as part of the shift to a
    // fire-and-observe DM model (dm_registry/dm_inbox/dm_poll endpoints
    // removed together — 404 by absence, per that commit message).
    // No replacement to port to: the current DM surface is dm_send,
    // dm_reply, dm_ack, dm_targets, dm_broadcast.

}

// Type-erased Encodable shim so XCTest can JSONEncode `any Encodable` results
// without a concrete type at the call site.
private struct EncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
