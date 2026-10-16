import XCTest
import GRDB
@testable import Sonata

/// DispatchExclusion (2026-10-16). prStar's live_review names its fixer in
/// dmTarget; when /prfix ran from a pool worker, the fixer sat idle between
/// turns and the dispatcher handed it its own review (run 1308, PR #762).
/// Every test that asserts a worker was skipped also asserts another worker
/// was chosen, or that nothing was chosen, so a broken predicate can't pass
/// by matching nothing.
final class DispatchExclusionTests: XCTestCase {

    private let fixer = "worker-1111111111"
    private let fixerSession = "aaaaaaaa-0000-0000-0000-000000000001"
    private let fixerLabel = "sona-worker-1"
    private let other = "worker-2222222222"

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.makePool()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return pool
    }

    private func addWorker(_ pool: DatabasePool, id: String, session: String?, label: String, heartbeat: Int64 = nowMs()) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workers (workerId, sessionLabel, status, lastHeartbeat, registeredAt, sessionId)
                VALUES (?, ?, 'idle', ?, ?, ?)
            """, arguments: [id, label, heartbeat, heartbeat, session])
        }
    }

    private func addFixerAndOther(_ pool: DatabasePool) async throws {
        // The fixer has the FRESHER heartbeat, so plain selection
        // (ORDER BY lastHeartbeat DESC) would pick it: the exclusion is what
        // moves the choice to the other worker.
        try await addWorker(pool, id: other, session: "bbbbbbbb-0000-0000-0000-000000000002", label: "sona-worker-2", heartbeat: nowMs() - 5_000)
        try await addWorker(pool, id: fixer, session: fixerSession, label: fixerLabel)
    }

    // MARK: - Parsing task metadata

    func testIdsFromTaskMetadata() {
        XCTAssertEqual(DispatchExclusion.ids(fromTaskMetadata: #"{"event_type":"pr_review","excludeSessionIds":["worker-1"]}"#), ["worker-1"])
        XCTAssertEqual(DispatchExclusion.ids(fromTaskMetadata: #"{"excludeSessionIds":["a","",7,"b"]}"#), ["a", "b"],
                       "empty strings and non-strings are dropped")
        XCTAssertEqual(DispatchExclusion.ids(fromTaskMetadata: #"{"event_type":"pr_review"}"#), [])
        XCTAssertEqual(DispatchExclusion.ids(fromTaskMetadata: #"{"excludeSessionIds":"worker-1"}"#), [], "a bare string is not a list")
        XCTAssertEqual(DispatchExclusion.ids(fromTaskMetadata: "not json"), [])
        XCTAssertEqual(DispatchExclusion.ids(fromTaskMetadata: nil), [])
    }

    // MARK: - findIdleWorker

    func testUnexcludedSelectionStillPicksFreshestIdleWorker() async throws {
        let pool = try makePool()
        try await addFixerAndOther(pool)
        let picked = await SonataChannelServer(dbPool: pool).findIdleWorker()
        XCTAssertEqual(picked, fixer, "control: with no exclusion the fresher fixer is picked")
    }

    func testExclusionMatchesWorkerIdSessionIdOrLabel() async throws {
        let pool = try makePool()
        try await addFixerAndOther(pool)
        let server = SonataChannelServer(dbPool: pool)
        for handle in [fixer, fixerSession, fixerLabel] {
            let picked = await server.findIdleWorker(excluding: [handle])
            XCTAssertEqual(picked, other, "excluding by \(handle) must skip the fixer and pick the other idle worker")
        }
    }

    func testOnlyExcludedWorkerIdleMeansNoWorker() async throws {
        let pool = try makePool()
        try await addWorker(pool, id: fixer, session: fixerSession, label: fixerLabel)
        let server = SonataChannelServer(dbPool: pool)
        let unexcluded = await server.findIdleWorker()
        XCTAssertEqual(unexcluded, fixer, "control: the fixer is idle and eligible without the exclusion")
        let excluded = await server.findIdleWorker(excluding: [fixer])
        XCTAssertNil(excluded)
    }

    // MARK: - dispatchToChannel

    private struct EventRow: Sendable { let assignedTo: String?; let payload: String }

    private func events(_ pool: DatabasePool) async throws -> [EventRow] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT assignedTo, payload FROM workerEvents")
                .map { EventRow(assignedTo: $0["assignedTo"], payload: $0["payload"]) }
        }
    }

    private func status(_ pool: DatabasePool, _ worker: String) async throws -> String? {
        try await pool.read { db in try String.fetchOne(db, sql: "SELECT status FROM workers WHERE workerId = ?", arguments: [worker]) }
    }

    func testDispatchSkipsFixerAndCarriesExclusionOnEvent() async throws {
        let pool = try makePool()
        try await addFixerAndOther(pool)
        let eventId = await SonataChannelServer(dbPool: pool).dispatchToChannel(
            taskId: "T1", title: "prStar live_review", prompt: "/prstar-live-review",
            dispatchCycle: "1", excludeSessionIds: [fixer])
        XCTAssertNotNil(eventId)

        let rows = try await events(pool)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.assignedTo, other)
        let payload = try XCTUnwrap(rows.first?.payload.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json[DispatchExclusion.eventPayloadKey] as? [String], [fixer])
        let fixerStatus = try await status(pool, fixer)
        XCTAssertEqual(fixerStatus, "idle")
    }

    func testDispatchWaitsWhenFixerIsOnlyIdleWorker() async throws {
        let pool = try makePool()
        try await addWorker(pool, id: fixer, session: fixerSession, label: fixerLabel)
        let eventId = await SonataChannelServer(dbPool: pool).dispatchToChannel(
            taskId: "T1", title: "prStar live_review", prompt: "/prstar-live-review",
            dispatchCycle: "1", excludeSessionIds: [fixer])
        XCTAssertNil(eventId)
        let rows = try await events(pool)
        XCTAssertTrue(rows.isEmpty, "no event may be created for the fixer")
        let fixerStatus = try await status(pool, fixer)
        XCTAssertEqual(fixerStatus, "idle")
    }

    func testUnexcludedDispatchPayloadHasNoExclusionKey() async throws {
        let pool = try makePool()
        try await addFixerAndOther(pool)
        _ = await SonataChannelServer(dbPool: pool).dispatchToChannel(
            taskId: "T1", title: "prStar review", prompt: "/prstar-review", dispatchCycle: "1")
        let rows = try await events(pool)
        XCTAssertEqual(rows.first?.assignedTo, fixer)
        XCTAssertFalse((rows.first?.payload ?? "").contains(DispatchExclusion.eventPayloadKey))
    }

    // MARK: - Re-enqueued (pending) events: the claim endpoint

    private func addPendingEvent(_ pool: DatabasePool, id: String, payload: String) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO workerEvents (id, type, payload, priority, status, createdAt)
                VALUES (?, 'task', ?, 5, 'pending', ?)
            """, arguments: [id, payload, nowMs()])
        }
    }

    private func claim(_ pool: DatabasePool, as worker: String) async throws {
        let action = workerEventActions.first { $0.name == "worker_event_claim" }!
        _ = try await action.handler(ActionContext(params: ActionParams(["workerId": worker]), dbPool: pool))
    }

    private func assignee(_ pool: DatabasePool, _ event: String) async throws -> String? {
        try await pool.read { db in try String.fetchOne(db, sql: "SELECT assignedTo FROM workerEvents WHERE id = ?", arguments: [event]) }
    }

    func testClaimEndpointRefusesExcludedWorkerAndServesOther() async throws {
        let pool = try makePool()
        try await addFixerAndOther(pool)
        try await addPendingEvent(pool, id: "E1", payload: #"{"task_id":"T1","exclude_session_ids":["\#(fixerSession)"]}"#)

        try await claim(pool, as: fixer)
        let afterFixer = try await assignee(pool, "E1")
        XCTAssertNil(afterFixer, "the fixer (excluded by sessionId) must not claim its own review")
        let fixerStatus = try await status(pool, fixer)
        XCTAssertEqual(fixerStatus, "idle")

        try await claim(pool, as: other)
        let afterOther = try await assignee(pool, "E1")
        XCTAssertEqual(afterOther, other)
    }

    func testClaimEndpointUnaffectedForEventsWithoutExclusionOrJSON() async throws {
        let pool = try makePool()
        try await addFixerAndOther(pool)
        // A non-JSON payload must not break the claim query (json_each would
        // error on it without the json_valid guard).
        try await addPendingEvent(pool, id: "E0", payload: "raw prompt, not json")
        try await claim(pool, as: fixer)
        let assigned = try await assignee(pool, "E0")
        XCTAssertEqual(assigned, fixer)
    }

    // MARK: - eventPredicate (shared with MCPEventPusher's auto-assign)

    func testEventPredicateMatchesEachHandle() async throws {
        let pool = try makePool()
        try await addPendingEvent(pool, id: "E1", payload: #"{"task_id":"T1","exclude_session_ids":["\#(fixerLabel)"]}"#)
        func eligible(_ worker: String, _ session: String?, _ label: String?) async throws -> Bool {
            let p = DispatchExclusion.eventPredicate(workerId: worker, sessionId: session, sessionLabel: label)
            return try await pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT \(p.sql) FROM workerEvents WHERE id = 'E1'", arguments: p.arguments) ?? false
            }
        }
        let fixerEligible = try await eligible(fixer, fixerSession, fixerLabel)
        XCTAssertFalse(fixerEligible)
        let otherEligible = try await eligible(other, nil, "sona-worker-2")
        XCTAssertTrue(otherEligible, "control: a worker with a NULL sessionId is not excluded")
    }
}
