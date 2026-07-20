import XCTest
@testable import Sonata

/// Regression tests for the compileWiki preservation guard.
///
/// Every case here is drawn from a real dispatched manifest — the 2026-07-19
/// run, in which all ten dispatched pages needed preservation and zero needed
/// compiling. The numbers are the measured ones from that run.
final class WikiCompileGuardTests: XCTestCase {

    // Timestamps from the 7/19 run.
    private let lastCompiled07_07: Int64 = 1783_000_000_000
    private let memoryAt05_23: Int64 = 1779_565_523_132
    private let memoryAt07_17: Int64 = 1784_292_090_824

    private func candidate(
        slug: String,
        namespace: String? = "ns",
        topic: String? = "topic",
        filePath: String = "/tmp/nonexistent.md",
        lastCompiled: Int64 = 0,
        backingMemoryCount: Int = 5,
        newestBackingMemoryAt: Int64? = nil,
        collidingSlugs: [String] = [],
        hasPreserveMarker: Bool = false
    ) -> WikiCompileGuard.Candidate {
        WikiCompileGuard.Candidate(
            slug: slug,
            namespace: namespace,
            topic: topic,
            filePath: filePath,
            lastCompiled: lastCompiled,
            backingMemoryCount: backingMemoryCount,
            newestBackingMemoryAt: newestBackingMemoryAt,
            collidingSlugs: collidingSlugs,
            hasPreserveMarker: hasPreserveMarker
        )
    }

    // MARK: - Class 1: zero-backing-memory pages

    /// tool-trials/* and scout-pipeline return 0 memories — they are curated
    /// elsewhere. On 7/19 this covered 7 pages holding ~320KB.
    func testZeroBackingMemoriesIsPreserved() {
        let decision = WikiCompileGuard.decide(
            candidate(slug: "tool-trials/_ideas/index", backingMemoryCount: 0, newestBackingMemoryAt: nil)
        )
        XCTAssertTrue(decision.isPreserve)
        XCTAssertTrue(decision.reason.contains("0 backing memories"))
    }

    // MARK: - Class 2: curated append-logs with real backing memories

    /// sonata/learnings has 12 backing memories and a 494KB topic-grouped
    /// append-log. A nonzero count makes it look legitimate, so the zero-memory
    /// rule does not catch it — the explicit marker must.
    func testCuratedAppendLogNeedsExplicitMarker() {
        let unflagged = candidate(
            slug: "sonata/learnings",
            topic: "learnings",
            lastCompiled: 0,
            backingMemoryCount: 12,
            newestBackingMemoryAt: memoryAt07_17
        )
        XCTAssertEqual(WikiCompileGuard.decide(unflagged), .compile,
                       "a nonzero memory count with fresh memories looks compilable — this is exactly why the marker is required")

        let flagged = candidate(
            slug: "sonata/learnings",
            topic: "learnings",
            backingMemoryCount: 12,
            newestBackingMemoryAt: memoryAt07_17,
            hasPreserveMarker: true
        )
        let decision = WikiCompileGuard.decide(flagged)
        XCTAssertTrue(decision.isPreserve)
        XCTAssertTrue(decision.reason.contains("compile: preserve"))
    }

    /// The marker outranks every heuristic — a flagged page is never compiled
    /// even when all the numbers say it is safe.
    func testPreserveMarkerOutranksAllHeuristics() {
        let decision = WikiCompileGuard.decide(
            candidate(slug: "any", backingMemoryCount: 500, newestBackingMemoryAt: memoryAt07_17, hasPreserveMarker: true)
        )
        XCTAssertTrue(decision.isPreserve)
    }

    // MARK: - Class 3: topic collision

    /// sonata/sessions and sonata/goose-engine both carried topic="sonata" —
    /// the namespace name, not a real topic. The recipe would fetch one
    /// identical memory set and write identical content over both.
    func testTopicCollisionPreservesBothPages() {
        let sessions = candidate(
            slug: "sonata/sessions", namespace: "sonata", topic: "sonata",
            backingMemoryCount: 22, newestBackingMemoryAt: memoryAt05_23
        )
        let goose = candidate(
            slug: "sonata/goose-engine", namespace: "sonata", topic: "sonata",
            backingMemoryCount: 22, newestBackingMemoryAt: memoryAt05_23
        )

        let (compile, preserve) = WikiCompileGuard.partition([sessions, goose])
        XCTAssertTrue(compile.isEmpty)
        XCTAssertEqual(preserve.count, 2)
        XCTAssertTrue(preserve.allSatisfy { $0.1.contains("shared with") })
        XCTAssertTrue(preserve.contains { $0.1.contains("sonata/goose-engine") })
        XCTAssertTrue(preserve.contains { $0.1.contains("sonata/sessions") })
    }

    /// A page that is the sole holder of its selector is not a collision.
    func testUniqueSelectorIsNotACollision() {
        let a = candidate(slug: "sonata/sessions", namespace: "sonata", topic: "sessions",
                          backingMemoryCount: 3, newestBackingMemoryAt: memoryAt07_17)
        let b = candidate(slug: "sonata/goose-engine", namespace: "sonata", topic: "goose-engine",
                          backingMemoryCount: 3, newestBackingMemoryAt: memoryAt07_17)
        let (compile, preserve) = WikiCompileGuard.partition([a, b])
        XCTAssertEqual(compile.count, 2)
        XCTAssertTrue(preserve.isEmpty)
    }

    // MARK: - Stale dirty flag

    /// All 22 topic="sonata" memories date from 2026-05-23 while both files were
    /// last compiled 7/07 — flagged dirty with zero new content. The dirty flag
    /// is a claim; the memory timestamps are the measurement.
    func testDirtyWithNoNewerMemoryIsPreserved() {
        let decision = WikiCompileGuard.decide(
            candidate(slug: "sonata/sessions", lastCompiled: lastCompiled07_07,
                      backingMemoryCount: 22, newestBackingMemoryAt: memoryAt05_23)
        )
        XCTAssertTrue(decision.isPreserve)
        XCTAssertTrue(decision.reason.contains("predates lastCompiled"))
    }

    func testFreshMemoryAfterLastCompileIsCompiled() {
        XCTAssertEqual(
            WikiCompileGuard.decide(
                candidate(slug: "fresh", lastCompiled: lastCompiled07_07,
                          backingMemoryCount: 4, newestBackingMemoryAt: memoryAt07_17)
            ),
            .compile
        )
    }

    /// A never-compiled page (lastCompiled == 0) must not be caught by the
    /// staleness rule — there is no prior compile to be stale against.
    func testNeverCompiledPageIsCompiled() {
        XCTAssertEqual(
            WikiCompileGuard.decide(
                candidate(slug: "brand-new", lastCompiled: 0,
                          backingMemoryCount: 4, newestBackingMemoryAt: memoryAt05_23)
            ),
            .compile
        )
    }

    // MARK: - The full 7/19 manifest

    /// End-to-end: the exact ten pages dispatched on 2026-07-19, with their
    /// measured counts. Every one must be preserved and none dispatched.
    func testFull0719ManifestPreservesAllTenPages() {
        let toolTrialCandidates = [
            "tool-trials/_candidates/2026-07-18-gcloud-always-on-memory",
            "tool-trials/_candidates/2026-07-18-code-review-graph",
            "tool-trials/_candidates/2026-07-18-context7",
            "tool-trials/_candidates/2026-07-18-llm-cliche-highlighter",
            "tool-trials/_candidates/2026-07-18-litert-js",
        ].map {
            candidate(slug: $0, namespace: "tool-trials", topic: ($0 as NSString).lastPathComponent,
                      lastCompiled: lastCompiled07_07, backingMemoryCount: 0, newestBackingMemoryAt: nil)
        }

        let rest = [
            candidate(slug: "scout-pipeline", namespace: "scout-pipeline", topic: nil,
                      lastCompiled: lastCompiled07_07, backingMemoryCount: 0, newestBackingMemoryAt: nil),
            candidate(slug: "tool-trials/_ideas/index", namespace: "tool-trials", topic: "index",
                      lastCompiled: lastCompiled07_07, backingMemoryCount: 0, newestBackingMemoryAt: nil),
            // 12 memories, 494KB append-log — caught only by the marker.
            candidate(slug: "sonata/learnings", namespace: "sonata", topic: "learnings",
                      lastCompiled: lastCompiled07_07, backingMemoryCount: 12,
                      newestBackingMemoryAt: memoryAt07_17, hasPreserveMarker: true),
            // Both carry topic="sonata" — collision AND stale.
            candidate(slug: "sonata/sessions", namespace: "sonata", topic: "sonata",
                      lastCompiled: lastCompiled07_07, backingMemoryCount: 22,
                      newestBackingMemoryAt: memoryAt05_23),
            candidate(slug: "sonata/goose-engine", namespace: "sonata", topic: "sonata",
                      lastCompiled: lastCompiled07_07, backingMemoryCount: 22,
                      newestBackingMemoryAt: memoryAt05_23),
        ]

        let (compile, preserve) = WikiCompileGuard.partition(toolTrialCandidates + rest)
        XCTAssertTrue(compile.isEmpty, "the 7/19 run needed zero compiles; got \(compile.map(\.slug))")
        XCTAssertEqual(preserve.count, 10)
    }

    // MARK: - Frontmatter parsing

    func testParsesPreserveMarkerFromFrontmatter() {
        XCTAssertTrue(WikiCompileGuard.hasPreserveMarker(inContent: """
        ---
        title: Learnings
        compile: preserve
        ---

        # Learnings
        """))
    }

    func testMarkerIsCaseAndQuoteTolerant() {
        XCTAssertTrue(WikiCompileGuard.hasPreserveMarker(inContent: "---\nCompile: \"Preserve\"\n---\n"))
    }

    func testNoFrontmatterMeansNoMarker() {
        XCTAssertFalse(WikiCompileGuard.hasPreserveMarker(inContent: "# Learnings\n\ncompile: preserve\n"))
    }

    /// A `compile:` line in the body, past the closing `---`, is prose — not a flag.
    func testMarkerAfterFrontmatterCloseIsIgnored() {
        XCTAssertFalse(WikiCompileGuard.hasPreserveMarker(inContent: """
        ---
        title: Notes
        ---

        compile: preserve
        """))
    }

    func testOtherCompileValuesDoNotPreserve() {
        XCTAssertFalse(WikiCompileGuard.hasPreserveMarker(inContent: "---\ncompile: auto\n---\n"))
    }

    func testMissingFileIsNotPreserved() {
        XCTAssertFalse(WikiCompileGuard.hasPreserveMarker(atPath: "/tmp/definitely-not-a-real-wiki-page-93813.md"))
    }
}
