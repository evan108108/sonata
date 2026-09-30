import XCTest
import GRDB
@testable import Sonata

// Event model attribution books tokens against the model the worker ACTUALLY
// ran on (workers.model), not the payload's requested `model`. The payload is a
// request nothing honours: TaskDispatcher never routes on tasks.model, so a
// prStar review with model "sonnet" ran on whatever the pool worker was — and
// was booked as the payload said (or, with no payload model, as the default).
final class WorkerModelAttributionTests: XCTestCase {

    // MARK: - resolveAttributedModel (pure)

    func testWorkerModelBeatsPayloadModel() {
        XCTAssertEqual(
            resolveAttributedModel(workerModel: "claude-opus-5-5", payload: #"{"model":"sonnet"}"#),
            "claude-opus-5-5")
    }

    func testPayloadModelOnlyWhenWorkerModelUnknown() {
        XCTAssertEqual(
            resolveAttributedModel(workerModel: nil, payload: #"{"model":"claude-sonnet-5-5"}"#),
            "claude-sonnet-5-5")
        XCTAssertEqual(
            resolveAttributedModel(workerModel: "", payload: #"{"model":"claude-sonnet-5-5"}"#),
            "claude-sonnet-5-5", "an empty worker model is unknown, not a model")
    }

    func testDefaultWhenNeitherIsKnown() {
        XCTAssertEqual(resolveAttributedModel(workerModel: nil, payload: "{}"), ModelPricing.defaultModel)
        XCTAssertEqual(resolveAttributedModel(workerModel: nil, payload: nil), ModelPricing.defaultModel)
        XCTAssertEqual(resolveAttributedModel(workerModel: nil, payload: "not json"), ModelPricing.defaultModel)
    }

    // MARK: - Transcript model reading

    private func turn(model: String, isSidechain: Bool = false) -> String {
        let sidechain = isSidechain ? #""isSidechain":true,"# : ""
        return """
        {"type":"assistant",\(sidechain)"message":{"model":"\(model)","usage":{"input_tokens":1,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}
        """
    }

    func testTranscriptModelIsLastMainTurn() throws {
        let jsonl = [
            turn(model: "claude-opus-5"),
            turn(model: "claude-opus-5-5"),
            turn(model: "claude-haiku-4-5", isSidechain: true),
        ].joined(separator: "\n")
        XCTAssertEqual(try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl)).model, "claude-opus-5-5")
    }

    /// Claude Code writes `<synthetic>` on the placeholder turns it fabricates
    /// for API errors. It names no model, so the last real one must survive it.
    func testSyntheticTurnDoesNotOverwriteModel() throws {
        let jsonl = [
            turn(model: "claude-opus-5-5"),
            turn(model: "<synthetic>"),
        ].joined(separator: "\n")
        XCTAssertEqual(try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl)).model, "claude-opus-5-5")
    }

    // MARK: - End to end through complete_event / fail_event

    private func seed(_ h: MCPTestHarness, worker: String, event: String, workerModel: String?) async throws {
        let now = nowMs()
        try await h.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO workers
                    (workerId, sessionLabel, status, lastHeartbeat, registeredAt, currentEventId, currentEventTokens, model)
                VALUES (?, 'sona-worker-1', 'busy', ?, ?, ?, 12345, ?)
            """, arguments: [worker, now, now, event, workerModel])
            try db.execute(sql: """
                INSERT INTO workerEvents
                    (id, type, payload, priority, status, assignedTo, createdAt, assignedAt)
                VALUES (?, 'task', '{"model":"sonnet","title":"prStar review"}', 5, 'assigned', ?, ?, ?)
            """, arguments: [event, worker, now, now])
        }
    }

    private func call(_ h: MCPTestHarness, as worker: String, tool: String, args: [String: Any]) async throws {
        let raw = await h.handle(
            sessionKey: worker, role: .worker,
            method: "tools/call", id: 1,
            params: ["name": tool, "arguments": args])
        let response = try XCTUnwrap(raw).data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(tool) errored: \(result)")
    }

    private func booked(_ h: MCPTestHarness, event: String) async throws -> (model: String?, tokens: Int64?, status: String?) {
        try await h.dbPool.read { db in
            let r = try Row.fetchOne(db, sql: "SELECT model, totalTokens, status FROM workerEvents WHERE id = ?", arguments: [event])
            return (r?["model"], r?["totalTokens"], r?["status"])
        }
    }

    func testCompleteBooksWorkerModelNotPayloadModel() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await seed(h, worker: "W_OPUS", event: "E_PR", workerModel: "claude-opus-5-5")

        try await call(h, as: "W_OPUS", tool: "complete_event", args: ["event_id": "E_PR", "result": "approve"])

        let b = try await booked(h, event: "E_PR")
        XCTAssertEqual(b.status, "completed")
        XCTAssertEqual(b.model, "claude-opus-5-5", "must book the worker's model, not payload 'sonnet'")
        XCTAssertEqual(b.tokens, 12345)
    }

    func testFailBooksWorkerModelNotPayloadModel() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await seed(h, worker: "W_OPUS", event: "E_PR", workerModel: "claude-opus-5-5")

        try await call(h, as: "W_OPUS", tool: "fail_event", args: ["event_id": "E_PR", "error": "boom"])

        let b = try await booked(h, event: "E_PR")
        XCTAssertEqual(b.status, "failed")
        XCTAssertEqual(b.model, "claude-opus-5-5")
    }

    func testCompleteFallsBackToPayloadWhenWorkerModelUnknown() async throws {
        let h = try MCPTestHarness.make()
        defer { h.teardown() }
        try await seed(h, worker: "W_NEW", event: "E_PR", workerModel: nil)

        try await call(h, as: "W_NEW", tool: "complete_event", args: ["event_id": "E_PR", "result": "ok"])

        let b = try await booked(h, event: "E_PR")
        XCTAssertEqual(b.model, "sonnet")
    }
}
