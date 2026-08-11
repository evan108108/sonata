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

    // MARK: - Sender-affinity routing for inbound sonar_dm workerEvents
    //
    // Regression harness for the 2026-08-11 sona-worker-2 incident: Scout
    // sent one design question twice within ~2 min; because the sonar_dm
    // idempotency key is scoped to message_id (fresh per send), both sends
    // materialized as separate workerEvents assigned to two workers, and
    // both workers began independently answering the same question.
    //
    // The fix routes any new sonar_dm from a peer/session already holding
    // an ASSIGNED sonar_dm to the same worker, so the plural-agent
    // failure mode is structurally unreachable. These tests exercise the
    // pre-assign path, the fallback pending path, the sibling_events digest
    // in the payload, and the peer_id → peer_name → session_id fallback
    // ladder in identity matching.

    private func makePoolWithWorkerEvents() throws -> DatabasePool {
        // Different dm_messages shape than makeInMemoryDbPool — this one
        // matches the DMAudit.insert column set (resolvedSessionKey,
        // resolvedKind, senderSessionKey, senderPeerName, inReplyToMessageId,
        // direction, failureReason). Without those columns the audit write
        // in routePeerInbound throws silently (wrapped in `try?`), which
        // doesn't affect the workerEvents insert we care about, but keeps
        // the sqlite log noisy and makes debug reads harder.
        let tmp = NSTemporaryDirectory() + "sonata-dm-affinity-test-\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let pool = try DatabasePool(path: tmp)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS dm_messages (
                    messageId           TEXT PRIMARY KEY,
                    targetSessionId     TEXT NOT NULL,
                    resolvedSessionKey  TEXT,
                    resolvedKind        TEXT,
                    senderSessionKey    TEXT,
                    senderPeerName      TEXT,
                    body                TEXT NOT NULL,
                    context             TEXT,
                    sentAtMs            INTEGER NOT NULL,
                    receivedAtMs        INTEGER NOT NULL,
                    deliveryStatus      TEXT NOT NULL,
                    inReplyToMessageId  TEXT,
                    direction           TEXT NOT NULL,
                    failureReason       TEXT,
                    fromSessionId       TEXT
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS workerEvents (
                    id             TEXT PRIMARY KEY,
                    type           TEXT NOT NULL,
                    payload        TEXT NOT NULL,
                    priority       INTEGER NOT NULL DEFAULT 5,
                    assignedTo     TEXT,
                    status         TEXT NOT NULL DEFAULT 'pending',
                    result         TEXT,
                    createdAt      INTEGER NOT NULL,
                    assignedAt     INTEGER,
                    completedAt    INTEGER,
                    sessionId      TEXT,
                    idempotencyKey TEXT
                )
            """)
            // Full (non-partial) unique index — matches production's v29
            // migration. v28 shipped a partial `WHERE idempotencyKey IS NOT
            // NULL` variant, but SQLite's `ON CONFLICT(col) DO NOTHING` needs
            // a non-partial UNIQUE target, so v29 dropped and replaced. If a
            // test schema uses the partial form, every INSERT throws "ON
            // CONFLICT clause does not match any PRIMARY KEY or UNIQUE
            // constraint" (which is exactly what tripped me up 2026-08-11).
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_workerEvents_idempotencyKey
                    ON workerEvents(idempotencyKey)
            """)
        }
        return pool
    }

    private func inboundSonarDMPayload(
        peerName: String = "scout",
        peerId: String = "peer-scout",
        sessionId: String = "session-scout-1",
        body: String,
        messageIdOverride: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "from_peer_name": peerName,
            "from_peer_id": peerId,
            "from_session_id": sessionId,
            "sender_display": "Scout",
            "body": body,
            "context": "",
        ]
        if let mid = messageIdOverride { payload["message_id"] = mid }
        return payload
    }

    private func seedAssignedSonarDM(
        pool: DatabasePool,
        workerId: String,
        workerSessionId: String,
        peerName: String,
        peerId: String,
        sessionId: String,
        messageId: String
    ) throws {
        try pool.write { db in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let payload = try JSONSerialization.data(withJSONObject: [
                "message_id": messageId,
                "from_peer_name": peerName,
                "from_peer_id": peerId,
                "from_session_id": sessionId,
                "body": "prior question",
            ])
            try db.execute(sql: """
                INSERT INTO workerEvents
                    (id, type, payload, priority, status, assignedTo,
                     assignedAt, sessionId, createdAt, idempotencyKey)
                VALUES (?, 'sonar_dm', ?, 5, 'assigned', ?, ?, ?, ?, ?)
            """, arguments: [
                UUID().uuidString, String(data: payload, encoding: .utf8) ?? "{}",
                workerId, now, workerSessionId, now, "sonar_dm:\(messageId)",
            ])
        }
    }

    private struct DMEventRow: Decodable, FetchableRecord {
        let id: String
        let status: String
        let assignedTo: String?
        let sessionId: String?
        let payload: String
    }

    private func fetchLatestSonarDMEvent(pool: DatabasePool) throws -> DMEventRow? {
        // rowid DESC is monotonic-in-insert-order regardless of createdAt
        // clock ticks — the seeded prior + newly-routed event routinely
        // share the same nowMs() and lexical UUID compare on id is
        // undefined, so a createdAt+id sort could return the seeded row.
        try pool.read { db in
            try DMEventRow.fetchOne(db, sql: """
                SELECT id, status, assignedTo, sessionId, payload
                FROM workerEvents
                WHERE type = 'sonar_dm'
                ORDER BY rowid DESC
                LIMIT 1
            """)
        }
    }

    private func siblingMessageIds(payloadJSON: String) -> [String] {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = obj["sibling_events"] as? [[String: Any]]
        else { return [] }
        return siblings.compactMap { $0["message_id"] as? String }
    }

    func testInboundSonarDMPreAssignsToWorkerHoldingSiblingFromSamePeer() async throws {
        let pool = try makePoolWithWorkerEvents()

        try seedAssignedSonarDM(
            pool: pool,
            workerId: "sona-worker-2", workerSessionId: "session-w2",
            peerName: "scout", peerId: "peer-scout", sessionId: "session-scout-1",
            messageId: "prior-msg-abc"
        )

        await DMActionsInbound.routePeerInbound(
            payload: inboundSonarDMPayload(body: "second design question", messageIdOverride: "new-msg-def"),
            dbPool: pool
        )

        // Exactly two sonar_dm events (the seeded prior + the newly-routed one).
        let total = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workerEvents WHERE type = 'sonar_dm'") ?? 0
        }
        XCTAssertEqual(total, 2)

        let latest = try XCTUnwrap(try fetchLatestSonarDMEvent(pool: pool))
        XCTAssertEqual(latest.status, "assigned")
        XCTAssertEqual(latest.assignedTo, "sona-worker-2")
        XCTAssertEqual(latest.sessionId, "session-w2")

        let siblings = siblingMessageIds(payloadJSON: latest.payload)
        XCTAssertEqual(siblings, ["prior-msg-abc"])
    }

    func testInboundSonarDMFallsBackToPendingWhenNoActiveSibling() async throws {
        let pool = try makePoolWithWorkerEvents()

        // No seeded sibling. The new event must land pending like today.
        await DMActionsInbound.routePeerInbound(
            payload: inboundSonarDMPayload(body: "fresh thread"),
            dbPool: pool
        )

        let latest = try XCTUnwrap(try fetchLatestSonarDMEvent(pool: pool))
        XCTAssertEqual(latest.status, "pending")
        XCTAssertNil(latest.assignedTo)
        XCTAssertNil(latest.sessionId)

        // Empty sibling_events list ships in the payload so a claiming worker
        // sees a definite "no overlap" rather than a missing field.
        XCTAssertEqual(siblingMessageIds(payloadJSON: latest.payload), [])
    }

    func testInboundSonarDMDoesNotPreAssignWhenSiblingHasCompleted() async throws {
        let pool = try makePoolWithWorkerEvents()

        // Prior event exists but has already completed — it no longer owns
        // the sender's thread, so a new DM should not affinity-route to the
        // now-idle worker.
        try await pool.write { db in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let payload = try JSONSerialization.data(withJSONObject: [
                "message_id": "prior-completed",
                "from_peer_id": "peer-scout",
            ])
            try db.execute(sql: """
                INSERT INTO workerEvents
                    (id, type, payload, priority, status, assignedTo,
                     assignedAt, completedAt, createdAt, idempotencyKey)
                VALUES (?, 'sonar_dm', ?, 5, 'completed', ?, ?, ?, ?, ?)
            """, arguments: [
                UUID().uuidString, String(data: payload, encoding: .utf8) ?? "{}",
                "sona-worker-2", now, now, now, "sonar_dm:prior-completed",
            ])
        }

        await DMActionsInbound.routePeerInbound(
            payload: inboundSonarDMPayload(body: "next thread"),
            dbPool: pool
        )

        let latest = try XCTUnwrap(try fetchLatestSonarDMEvent(pool: pool))
        XCTAssertEqual(latest.status, "pending")
        XCTAssertNil(latest.assignedTo)
        XCTAssertEqual(siblingMessageIds(payloadJSON: latest.payload), [])
    }

    func testInboundSonarDMDoesNotPreAssignWhenSiblingBelongsToDifferentPeer() async throws {
        let pool = try makePoolWithWorkerEvents()

        // Different peer entirely — active event exists, but it's not "us."
        try seedAssignedSonarDM(
            pool: pool,
            workerId: "sona-worker-3", workerSessionId: "session-w3",
            peerName: "other-peer", peerId: "peer-other", sessionId: "session-other-1",
            messageId: "prior-other"
        )

        await DMActionsInbound.routePeerInbound(
            payload: inboundSonarDMPayload(body: "unrelated thread"),
            dbPool: pool
        )

        let latest = try XCTUnwrap(try fetchLatestSonarDMEvent(pool: pool))
        XCTAssertEqual(latest.status, "pending")
        XCTAssertNil(latest.assignedTo)
    }

    func testInboundSonarDMFallsBackToPeerNameWhenPeerIdMissing() async throws {
        let pool = try makePoolWithWorkerEvents()

        // Seed a prior with the same peer_name but no peer_id — legacy shape.
        try seedAssignedSonarDM(
            pool: pool,
            workerId: "sona-worker-2", workerSessionId: "session-w2",
            peerName: "scout", peerId: "", sessionId: "session-scout-1",
            messageId: "prior-by-name"
        )

        // Inbound event carries only peer_name (no peer_id).
        var payload = inboundSonarDMPayload(peerId: "", body: "identity fallback")
        payload["from_peer_id"] = ""
        await DMActionsInbound.routePeerInbound(payload: payload, dbPool: pool)

        let latest = try XCTUnwrap(try fetchLatestSonarDMEvent(pool: pool))
        XCTAssertEqual(latest.status, "assigned")
        XCTAssertEqual(latest.assignedTo, "sona-worker-2")
        XCTAssertEqual(siblingMessageIds(payloadJSON: latest.payload), ["prior-by-name"])
    }

}

// Type-erased Encodable shim so XCTest can JSONEncode `any Encodable` results
// without a concrete type at the call site.
private struct EncodableShim: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
