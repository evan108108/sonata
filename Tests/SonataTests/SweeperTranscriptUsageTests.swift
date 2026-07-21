import XCTest
@testable import Sonata

// Regression tests for `parseTranscriptUsage` — the reading the sidecar context
// monitor rotates sessions on.
//
// WHY THIS FILE EXISTS
//
// The signal shipped once already, and it was wrong in a way nothing caught:
// `contextPercent` summed token usage across every assistant turn and then added
// `cacheRead` a second time on top of a figure that already contained it. Both
// errors are pure arithmetic. Neither crashes, neither logs, and both produce a
// confident Int. A live worker row read 15,890% "context used" for weeks. Six
// real transcripts, measured the superseded way, read between 2,217% and 17,475%
// — the numbers are recorded per-fixture in `expected.json` as
// `supersededProxyPercentAt200K` so the failure mode stays legible.
//
// It went unnoticed through review because nothing asserted on the number. That
// is the gap these tests close: every case below fails loudly on a specific
// integer rather than on "looks plausible."
//
// WHAT THE FIXTURES ARE
//
// `fixtures/transcript-usage/*.jsonl` are reduced captures of the six real
// sessions the algorithm was validated against — every field the parser reads,
// no conversation content. `fixtures/transcript-usage/regenerate.mjs` rebuilds
// them and refuses to write unless each reduction reproduces the full original's
// reading exactly, so the reduction cannot silently weaken the baseline.
//
// If a source change moves these numbers, that is this suite working. Regenerate
// only when the SOURCE sessions change.
final class SweeperTranscriptUsageTests: XCTestCase {

    /// Denominator the sidecar monitor divides by for a standard-window model.
    /// Matches `Sidecar.Defaults.contextWindowTokens`.
    private static let contextWindow: Int64 = 200_000

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "jsonl",
                subdirectory: "fixtures/transcript-usage"
            ),
            "missing fixture \(name).jsonl — run fixtures/transcript-usage/regenerate.mjs"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// One assistant turn. `usage` values are spelled out at each call site so a
    /// test reads as the arithmetic it is pinning.
    private func turn(
        input: Int,
        cacheCreate: Int,
        cacheRead: Int,
        output: Int,
        isSidechain: Bool = false
    ) -> String {
        let sidechain = isSidechain ? #""isSidechain":true,"# : ""
        return """
        {"type":"assistant",\(sidechain)"message":{"usage":{"input_tokens":\(input),\
        "cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead),\
        "output_tokens":\(output)}}}
        """
    }

    // MARK: - Core semantics

    /// The reading is the LAST turn, not the running total.
    ///
    /// This is the single most important property in the file. A sum is not a
    /// smaller-or-larger version of the right answer, it is a different quantity
    /// — every turn re-sends the whole conversation, so summing counts the same
    /// context once per turn and grows without bound.
    func testLastAssistantTurnCarriesTheReading() throws {
        let jsonl = [
            turn(input: 10, cacheCreate: 1_000, cacheRead: 20_000, output: 500),
            turn(input: 10, cacheCreate: 2_000, cacheRead: 40_000, output: 500),
            turn(input: 10, cacheCreate: 3_000, cacheRead: 60_000, output: 500),
        ].joined(separator: "\n")

        let usage = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl))

        // Turn 3 alone: 10 + 3,000 + 60,000.
        XCTAssertEqual(usage.contextTokens, 63_010)
        // NOT the sum of all three turns, which is what the superseded signal read.
        XCTAssertNotEqual(usage.contextTokens, 21_030 + 42_010 + 63_010)
        // The cumulative fields still sum — the panels and HealthMonitor read
        // those, and this change was additive to them.
        XCTAssertEqual(usage.inputTokens, 21_010 + 42_010 + 63_010)
    }

    /// A sub-agent's usage describes ITS window, not its parent's.
    ///
    /// This matters most for exactly the session type the feature exists for: a
    /// sidecar is a dispatcher that spawns an agent per event. Counting a
    /// sidechain turn would report the agent's context as the sidecar's, and
    /// because a fresh agent's window is small, the dispatcher would look emptier
    /// the busier it got.
    func testSidechainTurnsAreSkipped() throws {
        let jsonl = [
            turn(input: 5, cacheCreate: 1_000, cacheRead: 150_000, output: 200),
            // Dispatcher's real position — the last turn that counts.
            turn(input: 5, cacheCreate: 2_000, cacheRead: 160_000, output: 200),
            // Sub-agent turns land AFTER it in the file and are much smaller.
            turn(input: 5, cacheCreate: 100, cacheRead: 4_000, output: 50, isSidechain: true),
            turn(input: 5, cacheCreate: 200, cacheRead: 9_000, output: 50, isSidechain: true),
        ].joined(separator: "\n")

        let usage = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl))

        XCTAssertEqual(usage.contextTokens, 162_005, "should be the dispatcher's last turn")
        XCTAssertNotEqual(usage.contextTokens, 9_205, "must not be the sub-agent's window")
        // Sidechain turns are excluded from the cumulative sums too — they are
        // another session's spend, not this one's.
        XCTAssertEqual(usage.inputTokens, 151_005 + 162_005)
    }

    /// `cacheRead` is inside `input + cacheCreate + cacheRead` exactly once.
    ///
    /// The superseded signal added `currentCacheReadTokens` to
    /// `currentInputTokens`, where the former was already a component of the
    /// latter. That is a ~2x overstatement on a cache-heavy turn, which is every
    /// turn in a long session.
    func testCacheReadIsCountedOnce() throws {
        let jsonl = turn(input: 7, cacheCreate: 1_500, cacheRead: 98_000, output: 400)

        let usage = try XCTUnwrap(parseTranscriptUsage(jsonl: jsonl))

        XCTAssertEqual(usage.contextTokens, 99_507, "input + cacheCreate + cacheRead")
        XCTAssertEqual(usage.cacheReadTokens, 98_000)
        // The double-counted shape the old code produced.
        XCTAssertNotEqual(usage.contextTokens, 99_507 + 98_000)
        // Output belongs to the NEXT turn's input, never to this reading.
        XCTAssertNotEqual(usage.contextTokens, 99_507 + 400)
    }

    /// No turns yet reads as "no signal", never as an empty window.
    ///
    /// Zero would be indistinguishable from a genuinely empty context, and a
    /// freshly-spawned session that has not answered yet is the most common
    /// moment for the monitor to sample. `contextPercent` maps nil to "skip this
    /// tick"; it would map 0 to "plenty of room."
    func testEmptyTranscriptReadsNil() {
        XCTAssertNil(parseTranscriptUsage(jsonl: ""))
        XCTAssertNil(parseTranscriptUsage(jsonl: "\n\n"))
        // User turns only — the session exists but has not answered.
        XCTAssertNil(parseTranscriptUsage(jsonl: #"{"type":"user"}"#))
        // An assistant entry with no usage block is not a reading either.
        XCTAssertNil(parseTranscriptUsage(jsonl: #"{"type":"assistant","message":{}}"#))
    }

    /// DECIDED: malformed lines are SKIPPED, not thrown on.
    ///
    /// A transcript is a file another process is appending to. Reading it
    /// mid-write yields a torn final line routinely — that is an ordinary race,
    /// not corruption. Throwing would discard a perfectly good reading for every
    /// worker that happened to be writing, and the monitor would go blind under
    /// exactly the load that makes rotation matter. A torn tail costs at most one
    /// turn of staleness until the next 15s sweep.
    func testCorruptJSONLLineIsSkippedNotThrown() throws {
        let jsonl = [
            turn(input: 10, cacheCreate: 1_000, cacheRead: 20_000, output: 500),
            #"{"type":"assistant","message":{"usage":{"input_tokens":"#,  // torn mid-write
            "not json at all",
            turn(input: 10, cacheCreate: 2_000, cacheRead: 50_000, output: 500),
        ].joined(separator: "\n")

        let usage = try XCTUnwrap(
            parseTranscriptUsage(jsonl: jsonl),
            "a torn line must not discard the whole transcript"
        )
        XCTAssertEqual(usage.contextTokens, 52_010, "last INTACT turn wins")

        // A torn line as the final entry falls back to the last good turn rather
        // than reporting nothing.
        let tornTail = [
            turn(input: 10, cacheCreate: 1_000, cacheRead: 20_000, output: 500),
            #"{"type":"assist"#,
        ].joined(separator: "\n")
        XCTAssertEqual(try XCTUnwrap(parseTranscriptUsage(jsonl: tornTail)).contextTokens, 21_010)
    }

    // MARK: - Recorded baseline

    /// The six real sessions, pinned to the numbers they produced when the
    /// algorithm was validated by hand on 2026-07-21.
    ///
    /// Two of the six read over 100% of a 200K window (101% and 107%). Those are
    /// NOT bad data and must not be "fixed" by clamping: they are 1M-context
    /// sessions, correctly reporting more than 200K of occupancy. They are in the
    /// baseline on purpose, because an earlier stopgap proposed discarding any
    /// reading >= 100% as garbage — a filter that would have thrown away real
    /// over-threshold readings and hidden the wrong-denominator bug underneath.
    /// The denominator is per-sidecar (`Sidecar.contextWindowTokens`) precisely
    /// so these sessions divide by 1M and land near 21%.
    func testFixtureSessionsMatchRecordedReadings() throws {
        struct Expectation: Decodable {
            let session: String
            let totalTokens: Int64
            let inputTokens: Int64
            let cacheReadTokens: Int64
            let contextTokens: Int64
            let contextPercentAt200K: Int
            let supersededProxyPercentAt200K: Int
        }

        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "expected",
                withExtension: "json",
                subdirectory: "fixtures/transcript-usage"
            ),
            "missing expected.json — run fixtures/transcript-usage/regenerate.mjs"
        )
        let expectations = try JSONDecoder().decode(
            [Expectation].self, from: try Data(contentsOf: url))

        XCTAssertEqual(expectations.count, 6, "the baseline is six sessions")

        for expected in expectations {
            let usage = try XCTUnwrap(
                parseTranscriptUsage(jsonl: try fixture(expected.session)),
                "\(expected.session) produced no reading"
            )

            XCTAssertEqual(usage.contextTokens, expected.contextTokens, "\(expected.session) context")
            XCTAssertEqual(usage.totalTokens, expected.totalTokens, "\(expected.session) total")
            XCTAssertEqual(usage.inputTokens, expected.inputTokens, "\(expected.session) input")
            XCTAssertEqual(usage.cacheReadTokens, expected.cacheReadTokens, "\(expected.session) cacheRead")

            let pct = Int((usage.contextTokens * 100) / Self.contextWindow)
            XCTAssertEqual(pct, expected.contextPercentAt200K, "\(expected.session) percent")

            // Every one of these is a plausible occupancy figure. The superseded
            // signal produced none that were.
            XCTAssertLessThan(pct, 200, "\(expected.session) should read as occupancy, not a sum")
            XCTAssertGreaterThan(expected.supersededProxyPercentAt200K, 2_000,
                                 "\(expected.session) is only in the baseline because the old signal was absurd here")
        }

        // The recorded band. Note 47 and 80 where the original hand-validation
        // wrote 48 and 81: that pass computed percentages with a rounding
        // helper, while the shipping `contextPercent` floors via Int64 integer
        // division (47.859% and 80.938% exactly). The token readings themselves
        // never disagreed — only the derived percentage — and flooring is the
        // correct direction for a rotation threshold, since rounding 69.6% up
        // to 70% would rotate a session early. If this range moves, the
        // baseline moved.
        let percents = expectations.map(\.contextPercentAt200K).sorted()
        XCTAssertEqual(percents, [47, 70, 80, 84, 101, 107])
    }
}
