import CoreML
import Foundation
import Testing

@testable import Sonata

/// Parity of the Swift + CoreML classifier against the Python reference.
///
/// Fixtures come from the live pulpie service (`/simplify` + `/classify`) over
/// the four-page eval corpus; see
/// `fixtures/pulpie-classifier/regenerate.mjs`. They hold the exact block
/// strings the classifier consumes and the label Python assigned to each, so
/// these tests run offline with no service and no Python.
@Suite(.serialized)
struct PulpieClassifierTests {

    struct Block: Decodable {
        let itemId: String?
        let html: String
    }
    struct Fixture: Decodable {
        let page: String
        let blockCount: Int
        let mainCount: Int
        let blocks: [Block]
        let labels: [String?]
    }
    struct TokenCase: Decodable {
        let page: String
        let itemId: String?
        let html: String
        let ids: [Int]
    }
    struct TokenFixture: Decodable {
        let sepTokenId: Int
        let bosTokenId: Int
        let eosTokenId: Int
        let cases: [TokenCase]
    }

    static let pages = ["anthropic_newsroom", "chicago_permits", "usaspending_dod", "wikipedia_rag"]

    static func fixturesDirectory() throws -> URL {
        let base = Bundle.module.resourceURL ?? Bundle.module.bundleURL
        return base.appendingPathComponent("fixtures/pulpie-classifier", isDirectory: true)
    }

    static func loadFixture(_ name: String) throws -> Fixture {
        let url = try fixturesDirectory().appendingPathComponent("\(name).json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Skip rather than fail when a machine has neither the unpacked model nor
    /// a fetchable artifact (CI, fresh checkout).
    ///
    /// Deliberately also true when only the *source archive* is present: that
    /// lets these tests exercise the real download → checksum → unpack path.
    /// Gating on the unpacked model alone would mean bootstrap — the one piece
    /// that runs exactly once on a user's machine, where a mistake is most
    /// expensive — is never covered.
    static var modelAvailable: Bool {
        let fm = FileManager.default
        if fm.fileExists(
            atPath: PulpieModel.installDirectory
                .appendingPathComponent(PulpieModel.packageName).path)
        {
            return true
        }
        if PulpieModel.downloadURL.isFileURL {
            return fm.fileExists(atPath: PulpieModel.downloadURL.path)
        }
        return false
    }

    // MARK: Chunking (no model required)

    @available(macOS 15, *)
    @Test("packChunks reproduces the reference layout")
    func chunkLayout() throws {
        let blocks = [[1, 2, 3], [4, 5], [6]]
        let chunks = PulpieClassifier.packChunks(blockTokens: blocks)
        #expect(chunks.count == 1)
        // [BOS] 1 2 3 SEP 4 5 SEP 6 SEP [EOS]
        #expect(chunks[0].tokens == [128_000, 1, 2, 3, 128_256, 4, 5, 128_256, 6, 128_256, 128_001])
        #expect(chunks[0].blockIndices == [0, 1, 2])
    }

    @available(macOS 15, *)
    @Test("every block gets exactly one SEP, and indices line up with SEP order")
    func chunkSepAlignment() throws {
        // Sized so the packer is forced to split across several chunks.
        let blocks = (0..<400).map { i in Array(repeating: i + 10, count: 40) }
        let chunks = PulpieClassifier.packChunks(blockTokens: blocks)
        #expect(chunks.count > 1)

        var covered: [Int] = []
        for chunk in chunks {
            #expect(chunk.tokens.count <= 8192)
            #expect(chunk.tokens.first == 128_000)
            #expect(chunk.tokens.last == 128_001)
            let sepCount = chunk.tokens.filter { $0 == 128_256 }.count
            #expect(sepCount == chunk.blockIndices.count)
            covered += chunk.blockIndices
        }
        #expect(covered == Array(0..<400), "each block classified exactly once, in order")
    }

    @available(macOS 15, *)
    @Test("an oversized block is truncated, not dropped")
    func chunkOversizedBlock() throws {
        let huge = Array(repeating: 7, count: 20_000)
        let chunks = PulpieClassifier.packChunks(blockTokens: [[1, 2], huge, [3]])
        let covered = chunks.flatMap(\.blockIndices).sorted()
        #expect(covered == [0, 1, 2])
        for chunk in chunks { #expect(chunk.tokens.count <= 8192) }
    }

    // MARK: Tokenizer parity

    @available(macOS 15, *)
    @Test("tokenizer matches Python token-for-token", .enabled(if: modelAvailable))
    func tokenizerParity() async throws {
        let url = try Self.fixturesDirectory().appendingPathComponent("tokenizer-parity.json")
        let fixture = try JSONDecoder().decode(TokenFixture.self, from: Data(contentsOf: url))

        let classifier = PulpieClassifier()
        let mismatches = try await classifier.tokenizationMismatches(
            cases: fixture.cases.map { ($0.html, $0.ids) })

        #expect(
            mismatches.isEmpty,
            """
            \(mismatches.count)/\(fixture.cases.count) blocks tokenized differently than Python. \
            A single token of drift shifts every subsequent <|sep|> and corrupts labels downstream. \
            First: \(mismatches.prefix(2))
            """)
    }

    // MARK: Label parity

    @available(macOS 15, *)
    @Test("per-block labels match the Python reference", .enabled(if: modelAvailable), arguments: pages)
    func labelParity(page: String) async throws {
        let fixture = try Self.loadFixture(page)

        let classifier = PulpieClassifier()
        let got = try await classifier.classify(blocks: fixture.blocks.map(\.html))

        #expect(got.count == fixture.blocks.count)

        var mismatches: [String] = []
        for (i, expected) in fixture.labels.enumerated() {
            guard let expected else { continue }
            let actual = got[i].rawValue
            if actual != expected {
                mismatches.append("block[\(i)] item=\(fixture.blocks[i].itemId ?? "-") python=\(expected) swift=\(actual)")
            }
        }
        let labelled = fixture.labels.compactMap { $0 }.count
        #expect(
            mismatches.isEmpty,
            "\(page): \(labelled - mismatches.count)/\(labelled) match. Divergent: \(mismatches.prefix(8))")

        let mainCount = got.filter { $0 == .main }.count
        #expect(mainCount == fixture.mainCount, "\(page): main-block count drifted")
    }

    @available(macOS 15, *)
    @Test("cold start reports its breakdown", .enabled(if: modelAvailable))
    func coldStart() async throws {
        let classifier = PulpieClassifier()
        let metrics = try await classifier.warmUp()
        #expect(metrics.total > 0)
        print(
            """
            [pulpie] cold start \(String(format: "%.2f", metrics.total))s — \
            bootstrap \(String(format: "%.2f", metrics.bootstrapSeconds))s, \
            compile \(String(format: "%.2f", metrics.compileSeconds))s, \
            model load \(String(format: "%.2f", metrics.modelLoadSeconds))s, \
            tokenizer \(String(format: "%.2f", metrics.tokenizerLoadSeconds))s
            """)
    }

}
