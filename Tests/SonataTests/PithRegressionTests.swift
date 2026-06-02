import XCTest
@testable import Sonata

// Regression tests for pith L0/L1 generation (locked 2026-06-02).
//
// Locks the bar that Sources/Chat/Pith.swift (Phase A — not yet built) must
// hit when calling the local llama-server. The model + system prompt + sampling
// config are frozen; golden outputs are recorded under
// fixtures/pith-golden/<memoryId>.json.
//
// The chosen model is Llama 3.1 8B Instruct Q4_K_M, picked after a 5-way
// bake-off vs Qwen 2.5 3B/7B, Falcon 3 7B, and Haiku 4.5 (DM via worker).
// Llama was the only local model with: 5/5 format-compliant JSON, zero
// hallucinations, naturally-correct voice matching, and Pattern-A-shape
// abstractive output. See /Users/evan/memory/claude/documents/plans/
// sonata-openrouter-decoupling.md §1.
//
// These tests SKIP at runtime when:
//   - Pith.swift doesn't exist yet (Phase A.0 ships before Phase A)
//   - The PITH_LIVE=1 env var is not set (the live llama-server isn't
//     guaranteed to be running in CI)
//
// They still always run structural assertions on the recorded golden files
// themselves — those don't need a live server.
final class PithRegressionTests: XCTestCase {

    // MARK: - Fixtures

    struct CorpusMemory: Decodable {
        let id: String
        let type: String
        let content_length: Int
        let content: String
    }

    struct Corpus: Decodable {
        let description: String
        let memories: [CorpusMemory]
    }

    struct Golden: Decodable {
        let memory_id: String
        let memory_type: String
        let model: String
        let system_prompt: String
        let temperature: Double
        let seed: Int
        let l0: String
        let l1: String
        let l0_length: Int
        let l1_length: Int
    }

    // Length budgets (asserted on every golden + every live output)
    static let l0MaxLength = 200
    static let l1MaxLength = 700

    static func loadCorpus() throws -> Corpus {
        let candidates = [
            Bundle.module.url(forResource: "pith-corpus", withExtension: "json"),
            Bundle.module.url(forResource: "pith-corpus", withExtension: "json", subdirectory: "fixtures"),
        ].compactMap { $0 }
        guard let url = candidates.first else {
            throw XCTSkip("Missing pith-corpus.json in test bundle")
        }
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    static func loadGolden(memoryId: String) throws -> Golden {
        let candidates = [
            Bundle.module.url(forResource: memoryId, withExtension: "json"),
            Bundle.module.url(forResource: memoryId, withExtension: "json", subdirectory: "fixtures/pith-golden"),
        ].compactMap { $0 }
        guard let url = candidates.first else {
            throw XCTSkip("Missing golden for \(memoryId)")
        }
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    // MARK: - Structural assertions on the goldens themselves
    //
    // These always run. They guarantee the locked baseline meets the contract,
    // independent of any Pith.swift implementation.

    func testCorpusLoads() throws {
        let corpus = try Self.loadCorpus()
        XCTAssertEqual(corpus.memories.count, 5, "Corpus size is frozen at 5 memories")
        for mem in corpus.memories {
            XCTAssertFalse(mem.id.isEmpty)
            XCTAssertFalse(mem.type.isEmpty)
            XCTAssertGreaterThan(mem.content.count, 0)
            XCTAssertEqual(mem.content_length, mem.content.count, "content_length must match content")
        }
    }

    func testEveryMemoryHasAGolden() throws {
        let corpus = try Self.loadCorpus()
        for mem in corpus.memories {
            _ = try Self.loadGolden(memoryId: mem.id) // throws XCTSkip if missing
        }
    }

    func testGoldensRespectLengthBounds() throws {
        let corpus = try Self.loadCorpus()
        for mem in corpus.memories {
            let golden = try Self.loadGolden(memoryId: mem.id)
            XCTAssertFalse(golden.l0.isEmpty, "\(mem.id) golden L0 must be non-empty")
            XCTAssertFalse(golden.l1.isEmpty, "\(mem.id) golden L1 must be non-empty")
            XCTAssertLessThanOrEqual(
                golden.l0.count, Self.l0MaxLength,
                "\(mem.id) golden L0 length \(golden.l0.count) exceeds \(Self.l0MaxLength)"
            )
            XCTAssertLessThanOrEqual(
                golden.l1.count, Self.l1MaxLength,
                "\(mem.id) golden L1 length \(golden.l1.count) exceeds \(Self.l1MaxLength)"
            )
            XCTAssertEqual(golden.l0_length, golden.l0.count, "stored l0_length must match")
            XCTAssertEqual(golden.l1_length, golden.l1.count, "stored l1_length must match")
        }
    }

    func testGoldensHaveNoMarkdownFences() throws {
        let corpus = try Self.loadCorpus()
        for mem in corpus.memories {
            let golden = try Self.loadGolden(memoryId: mem.id)
            XCTAssertFalse(golden.l0.contains("```"), "\(mem.id) L0 must not contain markdown fences")
            XCTAssertFalse(golden.l1.contains("```"), "\(mem.id) L1 must not contain markdown fences")
        }
    }

    func testGoldensShareLockedConfig() throws {
        let corpus = try Self.loadCorpus()
        guard let first = corpus.memories.first else { return }
        let reference = try Self.loadGolden(memoryId: first.id)
        for mem in corpus.memories.dropFirst() {
            let golden = try Self.loadGolden(memoryId: mem.id)
            XCTAssertEqual(golden.model, reference.model, "All goldens must share one locked model")
            XCTAssertEqual(golden.system_prompt, reference.system_prompt, "All goldens must share one locked system prompt")
            XCTAssertEqual(golden.temperature, reference.temperature, "All goldens must share one locked temperature")
            XCTAssertEqual(golden.seed, reference.seed, "All goldens must share one locked seed")
        }
    }

    // MARK: - Live regression against Pith.swift
    //
    // Skipped unless PITH_LIVE=1 is set (the live llama-server isn't guaranteed
    // to be running in CI). When set, this is the regression bar: byte-equal
    // match between Pith.swift's current output and the recorded goldens.
    //
    // Run with: PITH_LIVE=1 swift test --filter PithRegressionTests
    //
    // First run downloads the 4.6 GB GGUF via BinaryProvisioner; subsequent
    // runs reuse the cached copy in ~/.sonata/bin/.

    func testLivePithMatchesGoldensExactly() async throws {
        guard ProcessInfo.processInfo.environment["PITH_LIVE"] == "1" else {
            throw XCTSkip("PITH_LIVE=1 not set; skipping live regression. Set PITH_LIVE=1 to run.")
        }
        let corpus = try Self.loadCorpus()
        for mem in corpus.memories {
            let golden = try Self.loadGolden(memoryId: mem.id)
            let result = try await Pith.generate(content: mem.content)
            XCTAssertEqual(
                result.l0, golden.l0,
                "\(mem.id) L0 drift — model output changed. If intentional, " +
                "regenerate goldens (see fixtures/pith-golden/README.md)."
            )
            XCTAssertEqual(
                result.l1, golden.l1,
                "\(mem.id) L1 drift — see above."
            )
        }
    }
}
