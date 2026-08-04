import XCTest
@testable import Sonata

// Tests for the decision that gives `workers.lastProgressAt` a ⊥.
//
// Before this rule existed the column was stamped with the sweep clock whenever
// a worker merely HELD an event, so it could not go stale and could not express
// "no progress". Every reader keyed on it was consequently dead, and a healthy
// worker doing minutes of `npm install` was indistinguishable from a hang —
// which is how sona-worker-2 came within minutes of being killed mid-ticket on
// 2026-08-03.
//
// The load-bearing case is `testUnchangedUsageDoesNotStamp`: it is the one that
// fails against the old behaviour, and the one whose regression would silently
// restore a column that always reads fresh.
final class SweeperProgressStampTests: XCTestCase {

    private func usage(
        total: Int64, input: Int64 = 0, cacheRead: Int64 = 0, context: Int64 = 0
    ) -> TranscriptUsage {
        TranscriptUsage(
            totalTokens: total, inputTokens: input,
            cacheReadTokens: cacheRead, contextTokens: context
        )
    }

    // MARK: - The defect

    /// Two consecutive samples with identical usage: the worker completed no
    /// model turn between them, so progress must NOT advance. This is the
    /// assertion the old `inFlight == nil ? nil : heartbeatAt` fails.
    func testUnchangedUsageDoesNotStamp() {
        XCTAssertFalse(shouldStampProgress(
            previous: ("s1", 5_000), sessionId: "s1", usage: usage(total: 5_000)
        ))
    }

    /// The complement: a turn landed, so progress advances. Without this the
    /// column would be honest but useless — permanently stale.
    func testChangedUsageStamps() {
        XCTAssertTrue(shouldStampProgress(
            previous: ("s1", 5_000), sessionId: "s1", usage: usage(total: 5_600)
        ))
    }

    /// A flat total with churn in the other fields is still no progress. Guards
    /// against someone "improving" this to compare the whole struct, which
    /// would make cache accounting alone read as work.
    func testFlatTotalWithMovingSubfieldsDoesNotStamp() {
        XCTAssertFalse(shouldStampProgress(
            previous: ("s1", 5_000),
            sessionId: "s1",
            usage: usage(total: 5_000, input: 4_000, cacheRead: 3_900, context: 180_000)
        ))
    }

    // MARK: - Sequence behaviour

    /// The heavy-IO worker, end to end: one turn, then four sweeps of silence
    /// while a build runs, then the turn that follows it. Exactly two stamps —
    /// and, critically, a run of consecutive sweeps that produce none.
    func testBuildStallProducesAGapThenResumes() {
        let readings: [Int64] = [1_000, 1_000, 1_000, 1_000, 1_000, 2_400]
        var previous: (sessionId: String?, total: Int64)? = ("s1", 400)
        var stamps: [Bool] = []

        for reading in readings {
            stamps.append(shouldStampProgress(
                previous: previous, sessionId: "s1", usage: usage(total: reading)
            ))
            previous = ("s1", reading)
        }

        XCTAssertEqual(stamps, [true, false, false, false, false, true])
    }

    // MARK: - Rotation

    /// A rotated session starts a fresh transcript whose totals restart near
    /// zero. That is a new run, not a stall — and a numeric comparison alone
    /// would read the drop as "changed" only by luck, so the session id is
    /// checked explicitly.
    func testRotationStampsEvenWhenTotalsShrink() {
        XCTAssertTrue(shouldStampProgress(
            previous: ("s1", 900_000), sessionId: "s2", usage: usage(total: 500)
        ))
    }

    /// Same id, smaller total — a truncated or replaced file on disk. Read as a
    /// different run of the session, i.e. activity, matching how
    /// `sidecarSpendDelta` treats the same shape.
    func testShrunkenTotalUnderTheSameSessionStamps() {
        XCTAssertTrue(shouldStampProgress(
            previous: ("s1", 900_000), sessionId: "s1", usage: usage(total: 500)
        ))
    }

    /// A nil session id on both sides is the same session — a worker row that
    /// has no sessionId yet — not a rotation every 15 seconds.
    func testNilSessionIdOnBothSidesIsNotARotation() {
        XCTAssertFalse(shouldStampProgress(
            previous: (nil, 1_000), sessionId: nil, usage: usage(total: 1_000)
        ))
    }

    // MARK: - Degenerate inputs

    /// No baseline: refuse to stamp. Stamping here would hand a genuinely
    /// stranded worker a fresh progress timestamp on every Sonata restart,
    /// restoring the blindness this change removes. A working worker loses at
    /// most one 15s tick.
    func testFirstSampleAfterProcessStartDoesNotStamp() {
        XCTAssertFalse(shouldStampProgress(
            previous: nil, sessionId: "s1", usage: usage(total: 5_000)
        ))
    }

    /// No reading at all — unresolvable or missing transcript. Stamp, because
    /// "cannot observe work" is not "no work happened" and this answer feeds a
    /// reaper that re-enqueues events. Fails safe toward the old behaviour.
    func testMissingReadingStampsRatherThanAssertingAHang() {
        XCTAssertTrue(shouldStampProgress(
            previous: ("s1", 5_000), sessionId: "s1", usage: nil
        ))
        XCTAssertTrue(shouldStampProgress(previous: nil, sessionId: nil, usage: nil))
    }
}
