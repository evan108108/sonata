import XCTest
@testable import Sonata

// Tests for the watermark arithmetic that turns cumulative transcript totals
// into per-sweep spend.
//
// This is the part of the spend feeder that fails silently. The ledger it feeds
// is a rolling budget guard, so an over-count throttles a healthy sidecar and an
// under-count lets one run past its cap — and neither shows up as an error, only
// as a number that was wrong all along. The rotation cases matter most: a
// sidecar rotates precisely when it has been busy, which is exactly when a
// mishandled reset would misattribute the most tokens.
final class SidecarSpendDeltaTests: XCTestCase {

    private func usage(total: Int64, input: Int64) -> TranscriptUsage {
        // `contextTokens` is irrelevant to spend — it measures occupancy, not
        // consumption — so it is parked at zero throughout.
        TranscriptUsage(
            totalTokens: total, inputTokens: input, cacheReadTokens: 0, contextTokens: 0
        )
    }

    // MARK: - First sample

    /// A fresh process has no watermark. The whole reading counts once, rather
    /// than being skipped (losing it) or counted every sweep thereafter.
    func testFirstSampleCountsTheFullReading() {
        let delta = sidecarSpendDelta(
            previous: nil, sessionId: "s1", usage: usage(total: 1_000, input: 800)
        )
        XCTAssertEqual(delta.input, 800)
        XCTAssertEqual(delta.output, 200)
    }

    // MARK: - Steady state

    func testSubsequentSampleCountsOnlyTheIncrement() {
        let delta = sidecarSpendDelta(
            previous: ("s1", 1_000, 800), sessionId: "s1", usage: usage(total: 1_500, input: 1_100)
        )
        XCTAssertEqual(delta.input, 300)
        XCTAssertEqual(delta.output, 200)
    }

    /// An idle sidecar is swept every 15s and must contribute nothing. If this
    /// regressed, spend would climb without the sidecar doing any work at all.
    func testUnchangedTotalsProduceNoSpend() {
        let delta = sidecarSpendDelta(
            previous: ("s1", 1_000, 800), sessionId: "s1", usage: usage(total: 1_000, input: 800)
        )
        XCTAssertEqual(delta.input, 0)
        XCTAssertEqual(delta.output, 0)
    }

    /// Output-only growth (a long generation off a cached prompt) still bills.
    func testOutputOnlyGrowthIsAttributed() {
        let delta = sidecarSpendDelta(
            previous: ("s1", 1_000, 800), sessionId: "s1", usage: usage(total: 1_400, input: 800)
        )
        XCTAssertEqual(delta.input, 0)
        XCTAssertEqual(delta.output, 400)
    }

    // MARK: - Rotation

    /// The case this function exists for. After a rotation the new transcript
    /// starts small; naive subtraction gives a large negative, which would
    /// clamp to zero and lose the new session's spend entirely.
    func testRotationToANewSessionCountsTheNewTotalInFull() {
        let delta = sidecarSpendDelta(
            previous: ("s1", 900_000, 700_000), sessionId: "s2", usage: usage(total: 500, input: 400)
        )
        XCTAssertEqual(delta.input, 400)
        XCTAssertEqual(delta.output, 100)
    }

    /// Same id but shrunken totals — a replaced or truncated file. Read as a new
    /// run rather than as negative spend.
    func testShrunkenTotalsUnderTheSameSessionAreTreatedAsAReset() {
        let delta = sidecarSpendDelta(
            previous: ("s1", 900_000, 700_000), sessionId: "s1", usage: usage(total: 500, input: 400)
        )
        XCTAssertEqual(delta.input, 400)
        XCTAssertEqual(delta.output, 100)
    }

    /// A nil session id on both sides is still "the same session" — it means the
    /// worker row has no sessionId yet, not that it rotated every 15 seconds.
    func testNilSessionIdOnBothSidesContinuesRatherThanResets() {
        let delta = sidecarSpendDelta(
            previous: (nil, 1_000, 800), sessionId: nil, usage: usage(total: 1_200, input: 900)
        )
        XCTAssertEqual(delta.input, 100)
        XCTAssertEqual(delta.output, 100)
    }

    // MARK: - Accumulation

    /// The property that actually matters: summing every delta across a
    /// session's sweeps reproduces that session's total exactly — no
    /// double-billing, no gaps — and a rotation starts the next one over.
    func testDeltasSumToTheTotalAcrossSweepsAndRotation() {
        let sweeps: [(String, TranscriptUsage)] = [
            ("s1", usage(total: 1_000, input: 800)),
            ("s1", usage(total: 2_500, input: 1_900)),
            ("s1", usage(total: 2_500, input: 1_900)),   // idle tick
            ("s1", usage(total: 4_000, input: 3_000)),
            ("s2", usage(total: 600, input: 500)),       // rotated
            ("s2", usage(total: 1_100, input: 900)),
        ]

        var watermark: (sessionId: String?, total: Int64, input: Int64)?
        var billedInput: Int64 = 0
        var billedOutput: Int64 = 0

        for (session, reading) in sweeps {
            let delta = sidecarSpendDelta(
                previous: watermark, sessionId: session, usage: reading
            )
            billedInput += delta.input
            billedOutput += delta.output
            watermark = (session, reading.totalTokens, reading.inputTokens)
        }

        // s1 finished at 4,000 total / 3,000 input; s2 reached 1,100 / 900.
        XCTAssertEqual(billedInput, 3_000 + 900)
        XCTAssertEqual(billedOutput, (4_000 - 3_000) + (1_100 - 900))
    }
}
