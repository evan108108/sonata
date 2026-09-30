import XCTest
@testable import Sonata

// Regression tests for the event-scoped half of `parseTranscriptUsage` — the
// numbers worker_event_complete/fail copy onto workerEvents.
//
// WHY THIS FILE EXISTS
//
// Two overcounts stacked on every booked event, and neither errors:
//
// 1. Session, not event. Pool sessions run event after event, and the sweeper
//    wrote the WHOLE transcript's sum into currentEventTokens. Every event was
//    booked with everything its session had run before it. prStar averaged
//    42.3M booked (n=219, 28 days) against ~10–12M of turns inside its window.
// 2. Line, not response. Claude Code writes one transcript line per content
//    block, each repeating the response's full usage, so one API call was
//    summed two to four times (a real worker transcript: 374 lines, 154
//    responses, 118.8M per-line vs 46.4M per-response).
//
// Each case below pins a specific integer, per the convention in
// SweeperTranscriptUsageTests: "looks plausible" is what let both ship.
final class SweeperEventScopedUsageTests: XCTestCase {

    /// 2026-09-30T12:56:28.461Z — an assignedAt with a non-zero millisecond
    /// part, so the boundary cases exercise the fraction, not just seconds.
    private static let assignedAt: Int64 = 1_790_772_988_461

    private func turn(
        id: String?,
        at timestamp: String?,
        input: Int = 10,
        cacheCreate: Int = 0,
        cacheRead: Int,
        output: Int = 100
    ) -> String {
        let idField = id.map { #""id":"\#($0)","# } ?? ""
        let tsField = timestamp.map { #""timestamp":"\#($0)","# } ?? ""
        return """
        {"type":"assistant",\(tsField)"message":{\(idField)"usage":{"input_tokens":\(input),\
        "cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead),\
        "output_tokens":\(output)}}}
        """
    }

    // MARK: - Window

    /// The defect itself: turns from the session's earlier events must not be
    /// booked to the event in flight, while the session totals still see them.
    func testEventSumsOnlyTurnsInsideTheWindow() throws {
        let jsonl = [
            turn(id: "msg_a", at: "2026-09-30T12:40:00.000Z", cacheRead: 1_000_000),  // previous event
            turn(id: "msg_b", at: "2026-09-30T12:50:00.000Z", cacheRead: 2_000_000),  // previous event
            turn(id: "msg_c", at: "2026-09-30T12:56:30.000Z", cacheRead: 3_000_000),  // this event
            turn(id: "msg_d", at: "2026-09-30T12:58:00.000Z", cacheRead: 4_000_000),  // this event
        ].joined(separator: "\n")

        let u = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl, since: Self.assignedAt))
        let event = try XCTUnwrap(u.event)

        XCTAssertEqual(event.cacheReadTokens, 7_000_000)
        XCTAssertEqual(event.inputTokens, 7_000_020)          // (10 + 0 + cacheRead) × 2
        XCTAssertEqual(event.totalTokens, 7_000_220)          // + output 100 × 2
        XCTAssertEqual(u.totalTokens, 10_000_440, "session totals keep every turn")
        XCTAssertEqual(u.contextTokens, 4_000_010, "context is still the last turn")
    }

    /// Inclusive at the exact millisecond, exclusive one millisecond before.
    func testWindowBoundaryIsInclusiveToTheMillisecond() throws {
        let jsonl = [
            turn(id: "msg_before", at: "2026-09-30T12:56:28.460Z", cacheRead: 5),
            turn(id: "msg_at", at: "2026-09-30T12:56:28.461Z", cacheRead: 7),
        ].joined(separator: "\n")

        let event = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl, since: Self.assignedAt)?.event)
        XCTAssertEqual(event.cacheReadTokens, 7)
    }

    /// No bound → no event reading at all. The sweeper writes nil, and COALESCE
    /// keeps the column rather than writing a session total back into it.
    func testNoBoundMeansNoEventReading() throws {
        let jsonl = turn(id: "msg_a", at: "2026-09-30T12:56:30.000Z", cacheRead: 1)
        XCTAssertNil(try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl)).event)
    }

    /// A bound with nothing inside it is a real zero, not a missing reading: the
    /// event has been assigned and hasn't produced a turn yet.
    func testBoundWithNoTurnsInsideReadsZero() throws {
        let jsonl = turn(id: "msg_a", at: "2026-09-30T12:00:00.000Z", cacheRead: 9_999)
        let event = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl, since: Self.assignedAt)?.event)
        XCTAssertEqual(event, .init(totalTokens: 0, inputTokens: 0, cacheReadTokens: 0))
    }

    /// A turn that can't be placed in time is outside every window. Booking it to
    /// whatever event is in flight is exactly how the original bug read.
    func testTurnWithoutTimestampIsExcludedFromTheEvent() throws {
        let jsonl = [
            turn(id: "msg_a", at: nil, cacheRead: 1_000),
            turn(id: "msg_b", at: "2026-09-30T12:57:00.000Z", cacheRead: 2_000),
        ].joined(separator: "\n")

        let u = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl, since: Self.assignedAt))
        XCTAssertEqual(u.event?.cacheReadTokens, 2_000)
        XCTAssertEqual(u.cacheReadTokens, 3_000)
    }

    /// Off the fast path: a timestamp not in Claude Code's fixed 24-char shape
    /// is parsed, not string-compared.
    func testNonCanonicalTimestampIsParsed() throws {
        let jsonl = [
            turn(id: "msg_a", at: "2026-09-30T12:56:28Z", cacheRead: 1),        // 461ms before
            turn(id: "msg_b", at: "2026-09-30T12:56:29+00:00", cacheRead: 10),  // after
        ].joined(separator: "\n")

        let event = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl, since: Self.assignedAt)?.event)
        XCTAssertEqual(event.cacheReadTokens, 10)
    }

    func testTranscriptTimestampRendersClaudeCodesFormat() {
        XCTAssertEqual(transcriptTimestamp(ms: Self.assignedAt), "2026-09-30T12:56:28.461Z")
        XCTAssertEqual(transcriptTimestamp(ms: 1_790_772_988_005), "2026-09-30T12:56:28.005Z")
        XCTAssertEqual(transcriptTimestamp(ms: 1_790_772_988_000), "2026-09-30T12:56:28.000Z")
    }

    // MARK: - One response, many lines

    /// One API response written as three content-block lines (thinking, text,
    /// tool_use) with identical usage is ONE call. Per-line summing tripled it.
    func testSplitResponseIsCountedOnce() throws {
        let jsonl = [
            turn(id: "msg_x", at: "2026-09-30T12:57:00.000Z", cacheRead: 100_000, output: 400),
            turn(id: "msg_x", at: "2026-09-30T12:57:00.100Z", cacheRead: 100_000, output: 400),
            turn(id: "msg_x", at: "2026-09-30T12:57:00.200Z", cacheRead: 100_000, output: 400),
            turn(id: "msg_y", at: "2026-09-30T12:57:05.000Z", cacheRead: 101_000, output: 50),
        ].joined(separator: "\n")

        let u = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl, since: Self.assignedAt))
        XCTAssertEqual(u.cacheReadTokens, 201_000)
        XCTAssertEqual(u.totalTokens, 201_470)                 // 100_010+400 + 101_010+50
        XCTAssertEqual(u.event?.totalTokens, 201_470)
    }

    /// Lines with no message id have nothing tying them together and keep the
    /// old per-line behaviour — which is also what the reduced fixtures rely on.
    func testLinesWithoutMessageIdAreEachCounted() throws {
        let jsonl = [
            turn(id: nil, at: "2026-09-30T12:57:00.000Z", cacheRead: 1_000),
            turn(id: nil, at: "2026-09-30T12:57:01.000Z", cacheRead: 1_000),
        ].joined(separator: "\n")

        XCTAssertEqual(try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl)).cacheReadTokens, 2_000)
    }
}
