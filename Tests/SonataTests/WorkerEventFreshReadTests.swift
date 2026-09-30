import XCTest
import GRDB
@testable import Sonata

// worker_event_complete / worker_event_fail take a FRESH event-scoped reading of
// the worker's transcript at completion, instead of trusting the swept
// currentEventTokens / currentInputTokens / currentCacheReadTokens.
//
// The swept columns lag by up to one sweep, and the turn that calls
// complete_event is by construction the last one, so it lands after the last
// sweep essentially every time. Booking the swept value dropped it.
//
// Each case pins exact integers.
final class WorkerEventFreshReadTests: XCTestCase {

    private static let assignedAt: Int64 = 1_790_772_988_461
    private static let sessionId = "0f0f0f0f-1111-2222-3333-444444444444"

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("-Users-evan--sonata-worker"),
            withIntermediateDirectories: true)
        WorkerTranscripts.projectsRootOverride = root.path
    }

    override func tearDownWithError() throws {
        WorkerTranscripts.projectsRootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func turn(id: String, atOffsetMs offset: Int64,
                      input: Int, cacheCreate: Int = 0, cacheRead: Int, output: Int) -> String {
        let ts = transcriptTimestamp(ms: Self.assignedAt + offset)
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"claude-opus-5-5",\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreate),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
        """
    }

    /// Earlier event's turn, one in-window turn the last sweep saw, and a final
    /// turn after the last sweep that Claude Code wrote as two content-block
    /// lines carrying the same usage.
    private func writeTranscript() throws {
        let jsonl = [
            turn(id: "m0", atOffsetMs: -60_000, input: 7, cacheRead: 1_000_000, output: 9),
            turn(id: "m1", atOffsetMs: 5_000, input: 10, cacheRead: 1_000, output: 100),
            turn(id: "m2", atOffsetMs: 30_000, input: 5, cacheCreate: 200, cacheRead: 3_000, output: 400),
            turn(id: "m2", atOffsetMs: 30_001, input: 5, cacheCreate: 200, cacheRead: 3_000, output: 400),
        ].joined(separator: "\n")
        try jsonl.write(
            to: root.appendingPathComponent("-Users-evan--sonata-worker/\(Self.sessionId).jsonl"),
            atomically: true, encoding: .utf8)
    }

    // What the fresh read must book: m1 + m2 once.
    private let expectedTotal: Int64 = 4_715       // (10 + 1,000 + 100) + (5 + 200 + 3,000 + 400)
    private let expectedInput: Int64 = 4_215       // (10 + 1,000) + (5 + 200 + 3,000)
    private let expectedCacheRead: Int64 = 4_000   // 1,000 + 3,000
    // What the last sweep saw: m1 only.
    private let sweptTotal: Int64 = 1_110
    private let sweptInput: Int64 = 1_010
    private let sweptCacheRead: Int64 = 1_000

    private func seed(_ h: MCPTestHarness, sessionId: String?) async throws {
        let now = nowMs()
        try await h.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO workers
                    (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentEventId,
                     sessionId, currentEventTokens, currentInputTokens, currentCacheReadTokens,
                     currentPromptHash, model)
                VALUES ('W1', 'sona-worker-1', 'busy', ?, ?, 'E1', ?, ?, ?, ?, 'h1', 'claude-opus-5-5')
            """, arguments: [now, now, sessionId, sweptTotal, sweptInput, sweptCacheRead])
            try db.execute(sql: """
                INSERT INTO workerEvents
                    (id, type, payload, priority, status, assignedTo, createdAt, assignedAt)
                VALUES ('E1', 'task', '{"title":"prStar review"}', 5, 'assigned', 'W1', ?, ?)
            """, arguments: [Self.assignedAt, Self.assignedAt])
        }
    }

    private func call(_ h: MCPTestHarness, tool: String, args: [String: Any]) async throws {
        let raw = await h.handle(
            sessionKey: "W1", role: .worker,
            method: "tools/call", id: 1,
            params: ["name": tool, "arguments": args])
        let response = try XCTUnwrap(raw).data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(tool) errored: \(result)")
    }

    private func booked(_ h: MCPTestHarness) async throws
        -> (tokens: Int64?, statsInput: Int64?, statsCacheRead: Int64?) {
        try await h.dbPool.read { db in
            let e = try Row.fetchOne(db, sql: "SELECT totalTokens FROM workerEvents WHERE id = 'E1'")
            let s = try Row.fetchOne(db, sql: """
                SELECT totalInputTokens, totalCacheReadTokens FROM promptCacheStats WHERE promptKey = 'task:h1'
            """)
            return (e?["totalTokens"], s?["totalInputTokens"], s?["totalCacheReadTokens"])
        }
    }

    func testCompleteBooksTurnStampedAfterLastSweep() async throws {
        try writeTranscript()
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await seed(h, sessionId: Self.sessionId)

        try await call(h, tool: "complete_event", args: ["event_id": "E1", "result": "approve"])

        let b = try await booked(h)
        XCTAssertEqual(b.tokens, expectedTotal, "final turn after the last sweep must be booked (swept: \(sweptTotal))")
        XCTAssertEqual(b.statsInput, expectedInput)
        XCTAssertEqual(b.statsCacheRead, expectedCacheRead)
    }

    func testFailBooksTurnStampedAfterLastSweep() async throws {
        try writeTranscript()
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await seed(h, sessionId: Self.sessionId)

        try await call(h, tool: "fail_event", args: ["event_id": "E1", "error": "boom"])

        let b = try await booked(h)
        XCTAssertEqual(b.tokens, expectedTotal)
        XCTAssertEqual(b.statsInput, expectedInput)
        XCTAssertEqual(b.statsCacheRead, expectedCacheRead)
    }

    /// No transcript on disk → the swept columns are booked, as before.
    func testFallsBackToSweptColumnsWithoutTranscript() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await seed(h, sessionId: Self.sessionId)

        try await call(h, tool: "complete_event", args: ["event_id": "E1", "result": "ok"])

        let b = try await booked(h)
        XCTAssertEqual(b.tokens, sweptTotal)
        XCTAssertEqual(b.statsInput, sweptInput)
        XCTAssertEqual(b.statsCacheRead, sweptCacheRead)
    }
}
