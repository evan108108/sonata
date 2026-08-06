import XCTest
@testable import Sonata

// The abstract layer must not answer a question the body leaves open.
//
// `Pith` compresses a memory body into l0/l1 at store time, and `mem_recall`'s
// MCP default tier is `l0` — so the synthesized layer is the one agents read,
// while the body where the question is correctly posed is the one nobody
// fetches. There is no confidence field: a manufactured resolution is
// byte-indistinguishable from a recorded one.
//
// The bias is structural rather than random. "asks whether X" compresses badly
// and "X is false" compresses well, so a summarizer reaches for the resolution.
// Observed twice in the same direction — 2026-07-26 over `--file`, and
// 2026-08-05 on memory a85d0e6f, whose body asked whether Scout's wave split
// was deliberate and whose l1 answered "The wave split was not deliberate"
// hours before Scout replied. That invention later happened to become true,
// which makes the failure undetectable by outcome.
//
// `uq-scout-wave-split` in the fixture carries that exact body, so this suite
// fails against the pre-2026-08-06 prompt. The `ctl-` cases guard the opposite
// failure: a prompt that buys uncertainty-preservation by hedging everything.
//
// REJECTED PHRASINGS, measured 2026-08-06 against `uq-scout-wave-split` — keep
// these before "simplifying" the clause in `Pith.systemPrompt`:
//
//   1. Terse imperative, appended last: "NEVER ANSWER A QUESTION THE SOURCE
//      LEAVES OPEN. If the source asks whether X, say that it asks whether X…"
//      → still emitted "the wave split was not deliberate". No effect.
//   2. Prohibition with a worked example: "an abstract may never resolve a
//      question the source leaves open… never pick A or B yourself."
//      → produced "The wave split is a deliberate question" — mangled, and it
//      resolved a DIFFERENT open-question case in the same run.
//   3. An earlier prohibition-shaped draft merely flipped the confabulation to
//      the opposite assertion ("The wave split was deliberate") — the failure
//      mode is reaching for A resolution, not for a particular one.
//
// What held was framing it as a check performed against the source before
// emitting, plus "Assert only what the source asserts" — a positive rule about
// provenance rather than a prohibition on a sentence shape.
//
// Live cases need PITH_LIVE=1 and the local llama-server, same as
// PithRegressionTests. Run: PITH_LIVE=1 swift test --filter PithUncertaintyTests
final class PithUncertaintyTests: XCTestCase {

    struct Case: Decodable {
        let id: String
        let kind: String        // "open_question" | "definite"
        let note: String
        let content: String
    }

    struct Fixture: Decodable {
        let description: String
        let cases: [Case]
    }

    /// Vocabulary that counts as preserving an open question. Deliberately
    /// broad: the point is that SOME uncertainty survived compression, not that
    /// the model picked a particular phrasing.
    static let uncertaintyMarkers = [
        "whether", "unresolved", "unclear", "open question", "remains open",
        "uncertain", "not yet", "cannot tell", "two readings", "ambiguous",
        "may be", "might", "could be", "possibly", "not known", "undetermined",
        "?",
    ]

    static func containsUncertaintyMarker(_ text: String) -> String? {
        let haystack = text.lowercased()
        return uncertaintyMarkers.first { haystack.contains($0) }
    }

    static func loadFixture() throws -> Fixture {
        let candidates = [
            Bundle.module.url(forResource: "pith-uncertainty", withExtension: "json"),
            Bundle.module.url(forResource: "pith-uncertainty", withExtension: "json", subdirectory: "fixtures"),
        ].compactMap { $0 }
        guard let url = candidates.first else {
            throw XCTSkip("Missing pith-uncertainty.json in test bundle")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    // MARK: - Structural (always run)

    func testFixtureCoversBothDirections() throws {
        let fixture = try Self.loadFixture()
        let open = fixture.cases.filter { $0.kind == "open_question" }
        let definite = fixture.cases.filter { $0.kind == "definite" }
        XCTAssertGreaterThanOrEqual(open.count, 3, "Need several open-question cases")
        XCTAssertGreaterThanOrEqual(
            definite.count, 2,
            "Need control cases, or a prompt that hedges everything would pass"
        )
        XCTAssertEqual(
            open.count + definite.count, fixture.cases.count,
            "Every case must be labelled open_question or definite"
        )
        for c in fixture.cases {
            XCTAssertFalse(c.content.isEmpty, "\(c.id) has empty content")
            XCTAssertFalse(c.note.isEmpty, "\(c.id) must say why it is in the corpus")
        }
    }

    /// The prompt is the fix. If the clause naming the constraint disappears,
    /// the live tests below would still pass on a good day and quietly stop
    /// testing anything on a bad one.
    func testSystemPromptStatesTheConstraint() {
        XCTAssertTrue(
            Pith.systemPrompt.contains("Assert only what the source asserts"),
            "Pith.systemPrompt lost its uncertainty-preservation clause"
        )
    }

    // MARK: - Live generation (PITH_LIVE=1)

    func testOpenQuestionsSurviveCompression() async throws {
        guard ProcessInfo.processInfo.environment["PITH_LIVE"] == "1" else {
            throw XCTSkip("PITH_LIVE=1 not set; skipping live pith generation.")
        }
        let fixture = try Self.loadFixture()
        for c in fixture.cases where c.kind == "open_question" {
            let result = try await Pith.generate(content: c.content)
            let combined = result.l0 + " " + result.l1
            XCTAssertNotNil(
                Self.containsUncertaintyMarker(combined),
                """
                \(c.id): the abstract resolved a question the body left open.
                note: \(c.note)
                l0: \(result.l0)
                l1: \(result.l1)
                """
            )
        }
    }

    func testDefiniteMemoriesAreNotHedged() async throws {
        guard ProcessInfo.processInfo.environment["PITH_LIVE"] == "1" else {
            throw XCTSkip("PITH_LIVE=1 not set; skipping live pith generation.")
        }
        let fixture = try Self.loadFixture()
        for c in fixture.cases where c.kind == "definite" {
            let result = try await Pith.generate(content: c.content)
            let combined = result.l0 + " " + result.l1
            let marker = Self.containsUncertaintyMarker(combined)
            XCTAssertNil(
                marker,
                """
                \(c.id): a settled memory came back hedged on "\(marker ?? "")".
                Preserving uncertainty must not cost certainty.
                note: \(c.note)
                l0: \(result.l0)
                l1: \(result.l1)
                """
            )
        }
    }
}
