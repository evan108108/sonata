import CoreML
import CryptoKit
import Foundation
import Tokenizers

// MARK: - Configuration
//
// Update these four together when a new model artifact is published.

/// Where the packaged model is fetched from on first use.
public enum PulpieModel {
    public static let downloadURL = URL(
        string: "https://huggingface.co/evan108108/pulpie-orange-small-coreml"
            + "/resolve/main/pulpie-orange-small-coreml-fp32.tar.gz")!

    /// SHA-256 of the tarball at `downloadURL`. Verified before unpacking.
    ///
    /// fp32-only bundle: 403,179,468 bytes. Verified to be a repackaging of the
    /// task #1 artifact, not a re-conversion — the fp32 `.mlpackage` is
    /// byte-identical, so the 920/920 parity numbers carry over.
    public static let sha256 = "116aeb6ca92b647c5b6536b2cd226c3d5961f82ec44bef6e6864627d93c14921"

    /// Expected size, so a truncated download fails with a clear message rather
    /// than a bare checksum mismatch.
    public static let expectedBytes = 403_179_468

    /// Unpacked location. Holds the .mlpackage plus the tokenizer sidecars.
    public static let installDirectory = URL(
        fileURLWithPath: NSString(string: "~/.sonata/models/pulpie-orange-small-coreml")
            .expandingTildeInPath, isDirectory: true)

    /// fp32, not fp16. fp32 reproduces the Python reference exactly (920/920
    /// block labels vs 912/920) *and* runs ~3x faster — the fp16 graph lands on
    /// an accelerated path that handles this model badly. fp16's only advantage
    /// is 406 MB vs 812 MB on disk.
    public static let packageName = "pulpie-orange-small-fp32.mlpackage"
}

/// The four artifact facts the first-use path depends on, gathered into one
/// value so a test can point them somewhere harmless.
///
/// This exists purely as a seam. `.default` is what ships, every production
/// call site takes it, and nothing here rewires behaviour — `PulpieClassifier`
/// reads these instead of reaching for `PulpieModel`'s statics directly, so
/// `PulpieBootstrapTests` can exercise download → checksum → unpack against a
/// synthetic archive in a temp directory instead of a 403 MB download into the
/// user's real install.
public struct PulpieBootstrap: Sendable {
    public var installDirectory: URL
    public var downloadURL: URL
    public var sha256: String
    public var expectedBytes: Int

    public init(installDirectory: URL, downloadURL: URL, sha256: String, expectedBytes: Int) {
        self.installDirectory = installDirectory
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.expectedBytes = expectedBytes
    }

    /// What ships.
    public static let `default` = PulpieBootstrap(
        installDirectory: PulpieModel.installDirectory,
        downloadURL: PulpieModel.downloadURL,
        sha256: PulpieModel.sha256,
        expectedBytes: PulpieModel.expectedBytes)
}

// MARK: - Model constants
//
// These mirror the Python reference (pulpie.chunker / pulpie.model_utils) and
// the converted graph's fixed input shape. Changing any of them silently
// changes which token a block's prediction is read from.

private enum Const {
    /// The converted model has a FIXED [1, 8192] input. Enumerated shapes were
    /// rejected during conversion: on the accelerated path they return garbage
    /// and can hard-crash CoreML's execution stream. Chunks are padded, never
    /// truncated to a shorter bucket.
    static let sequenceLength = 8192

    static let sepTokenID = 128_256  // <|sep|>, already in vocab (no resize)
    static let bosTokenID = 128_000  // <|begin_of_text|>
    static let eosTokenID = 128_001  // <|end_of_text|>
    /// `config.pad_token_id`, NOT the tokenizer's pad (128004). pulpie uses the
    /// config value; masked positions are ignored anyway, but matching keeps
    /// the inputs byte-identical to the reference.
    static let padTokenID = 128_001

    /// `Extractor(max_tokens=8192)`. Also the chunking budget — changing it
    /// changes chunk boundaries, and therefore the context each block is
    /// classified in, so it is NOT a free knob.
    static let maxTokens = 8192
}

// MARK: - Errors

public enum PulpieError: Error, CustomStringConvertible {
    case unsupportedOS
    case downloadFailed(URL, underlying: String)
    case checksumMismatch(expected: String, actual: String)
    case unpackFailed(String)
    case modelMissing(URL)
    case badOutput(String)

    public var description: String {
        switch self {
        case .unsupportedOS:
            return "PulpieClassifier requires macOS 15 or later (the CoreML model is built with minimum_deployment_target=macOS15)."
        case .downloadFailed(let url, let underlying):
            return "Failed to download the pulpie model from \(url.absoluteString): \(underlying)"
        case .checksumMismatch(let expected, let actual):
            return "Pulpie model checksum mismatch — refusing to unpack. expected \(expected), got \(actual)"
        case .unpackFailed(let detail):
            return "Failed to unpack the pulpie model: \(detail)"
        case .modelMissing(let url):
            return "Pulpie model not found at \(url.path)"
        case .badOutput(let detail):
            return "Unexpected CoreML output: \(detail)"
        }
    }
}

// MARK: - Classifier

/// Labels HTML blocks as main content or boilerplate, using the CoreML port of
/// `feyninc/pulpie-orange-small`.
///
/// The model is a *token* classifier over a packed sequence, not a
/// per-block classifier: blocks are concatenated as
/// `[BOS] b0 <|sep|> b1 <|sep|> ... [EOS]`, and block *i*'s verdict is the
/// argmax of the logits at the `<|sep|>` that follows it. One forward pass
/// labels every block in the chunk.
@available(macOS 15, *)
public actor PulpieClassifier {
    public static let shared = PulpieClassifier()

    public enum Label: String, Sendable, Equatable {
        case main
        case other
    }

    /// Timings from the last cold start, for reporting.
    public struct LoadMetrics: Sendable {
        public var bootstrapSeconds: Double = 0
        public var compileSeconds: Double = 0
        public var modelLoadSeconds: Double = 0
        public var tokenizerLoadSeconds: Double = 0
        public var total: Double { bootstrapSeconds + compileSeconds + modelLoadSeconds + tokenizerLoadSeconds }
    }

    private var model: MLModel?
    private var tokenizer: (any Tokenizer)?
    private(set) public var metrics = LoadMetrics()

    /// The artifact facts this instance bootstraps from.
    ///
    /// Production is always `.default`. Kept per-instance rather than as
    /// mutable globals so that `PulpieBootstrapTests` can point the first-use
    /// path at a throwaway directory and a synthetic archive: settable statics
    /// would be shared with every other suite in the same test process,
    /// including `PulpieClassifier.shared`.
    private let bootstrap: PulpieBootstrap

    public init(bootstrap: PulpieBootstrap = .default) {
        self.bootstrap = bootstrap
    }

    // MARK: Public API

    /// Classify block HTML strings, in document order.
    ///
    /// Returns one label per input block. Blocks whose `<|sep|>` falls outside
    /// the model's window default to `.other`, matching the reference's
    /// `predictions = [0] * len(blocks)` initialisation.
    public func classify(blocks: [String]) async throws -> [Label] {
        guard !blocks.isEmpty else { return [] }
        try await ensureLoaded()
        guard let model, let tokenizer else { throw PulpieError.modelMissing(packageURL) }

        let blockTokens = blocks.map { tokenizer.encode(text: $0, addSpecialTokens: false) }
        var predictions = [Int](repeating: 0, count: blocks.count)

        for chunk in Self.packChunks(blockTokens: blockTokens) {
            let logits = try Self.infer(model: model, tokens: chunk.tokens)
            // SEP positions appear in the same order as blockIndices, by
            // construction of packChunks.
            var sepOrdinal = 0
            for (position, token) in chunk.tokens.enumerated() where token == Const.sepTokenID {
                guard sepOrdinal < chunk.blockIndices.count else { break }
                let blockIndex = chunk.blockIndices[sepOrdinal]
                let base = position * 2
                predictions[blockIndex] = logits[base + 1] > logits[base] ? 1 : 0
                sepOrdinal += 1
            }
        }

        return predictions.map { $0 == 1 ? .main : .other }
    }

    /// Force the download/compile/load work to happen now rather than on the
    /// first `classify`. Returns the cold-start breakdown.
    @discardableResult
    public func warmUp() async throws -> LoadMetrics {
        try await ensureLoaded()
        return metrics
    }

    /// Tokenize each case and report the ones that disagree with the expected
    /// ids. Exposed for the parity test: tokenizer drift is the failure mode
    /// most likely to go unnoticed, because one extra token shifts every
    /// subsequent `<|sep|>` and silently corrupts labels rather than erroring.
    func tokenizationMismatches(cases: [(html: String, expected: [Int])]) async throws -> [String] {
        try await ensureLoaded()
        guard let tokenizer else { throw PulpieError.modelMissing(packageURL) }
        var mismatches: [String] = []
        for item in cases {
            let got = tokenizer.encode(text: item.html, addSpecialTokens: false)
            guard got != item.expected else { continue }
            var firstDiff = min(got.count, item.expected.count)
            for i in 0..<min(got.count, item.expected.count) where got[i] != item.expected[i] {
                firstDiff = i
                break
            }
            mismatches.append(
                "len python=\(item.expected.count) swift=\(got.count) firstDiff=\(firstDiff) "
                    + "html=\(item.html.prefix(80))")
        }
        return mismatches
    }

    // MARK: Loading

    private var packageURL: URL {
        bootstrap.installDirectory.appendingPathComponent(PulpieModel.packageName)
    }

    /// Compiled form is cached beside the package — compiling an 812 MB model
    /// on every launch would dominate cold start.
    private var compiledURL: URL {
        bootstrap.installDirectory.appendingPathComponent("pulpie-orange-small-fp32.mlmodelc")
    }

    private func ensureLoaded() async throws {
        if model != nil, tokenizer != nil { return }

        var m = LoadMetrics()
        var clock = ContinuousClock.now

        try await bootstrapIfNeeded()
        try verifyArtifactMatchesConstants()
        m.bootstrapSeconds = Self.elapsed(&clock)

        let compiled = try compileIfNeeded()
        m.compileSeconds = Self.elapsed(&clock)

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loaded = try MLModel(contentsOf: compiled, configuration: config)
        m.modelLoadSeconds = Self.elapsed(&clock)

        let tok = try await AutoTokenizer.from(modelFolder: bootstrap.installDirectory)
        m.tokenizerLoadSeconds = Self.elapsed(&clock)

        self.model = loaded
        self.tokenizer = tok
        self.metrics = m
    }

    private static func elapsed(_ from: inout ContinuousClock.Instant) -> Double {
        let now = ContinuousClock.now
        let d = from.duration(to: now)
        from = now
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Cross-check the compiled-in constants against the artifact's own
    /// `conversion_meta.json`.
    ///
    /// The token ids and sequence length live as constants (they belong at the
    /// top of this file, and are load-bearing for correctness), but that means
    /// a re-packaged or swapped artifact could silently disagree with them.
    /// The failure mode is not a crash: predictions get read from the wrong
    /// positions and every label quietly goes wrong. So verify, and refuse.
    private func verifyArtifactMatchesConstants() throws {
        let metaURL = bootstrap.installDirectory.appendingPathComponent("conversion_meta.json")
        guard let data = try? Data(contentsOf: metaURL),
            let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return  // Older artifacts may not carry it; absence is not a mismatch.
        }

        var problems: [String] = []
        func check(_ key: String, _ expected: Int) {
            guard let actual = meta[key] as? Int else { return }
            if actual != expected { problems.append("\(key): artifact=\(actual) code=\(expected)") }
        }
        check("sep_token_id", Const.sepTokenID)
        check("bos_token_id", Const.bosTokenID)
        check("eos_token_id", Const.eosTokenID)
        check("pad_token_id", Const.padTokenID)
        check("sequence_length", Const.sequenceLength)

        if let labels = meta["labels"] as? [String: String] {
            if let one = labels["1"], one != Label.main.rawValue {
                problems.append("labels.1: artifact=\(one) code=\(Label.main.rawValue)")
            }
            if let zero = labels["0"], zero != Label.other.rawValue {
                problems.append("labels.0: artifact=\(zero) code=\(Label.other.rawValue)")
            }
        }

        guard problems.isEmpty else {
            throw PulpieError.badOutput(
                "model artifact disagrees with compiled-in constants — refusing to run, "
                    + "labels would be silently wrong: " + problems.joined(separator: "; "))
        }
    }

    private func compileIfNeeded() throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: compiledURL.path) { return compiledURL }
        guard fm.fileExists(atPath: packageURL.path) else {
            throw PulpieError.modelMissing(packageURL)
        }
        let temporary = try MLModel.compileModel(at: packageURL)
        // compileModel writes to a temp location the system may reclaim; move
        // it next to the package so later launches skip compilation entirely.
        if fm.fileExists(atPath: compiledURL.path) { try? fm.removeItem(at: compiledURL) }
        do {
            try fm.moveItem(at: temporary, to: compiledURL)
        } catch {
            try? fm.removeItem(at: compiledURL)
            try fm.copyItem(at: temporary, to: compiledURL)
        }
        return compiledURL
    }

    /// Download + verify + unpack, once. No-op when the model is present.
    ///
    /// Internal rather than private so `PulpieBootstrapTests` can drive this
    /// path directly: it is the one path that runs exactly once on a real
    /// user's machine, and `classify` reaches it only after a CoreML compile
    /// and load that a hermetic test has no business paying for.
    func bootstrapIfNeeded() async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: packageURL.path) { return }

        try fm.createDirectory(
            at: bootstrap.installDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let tarball = try await Self.download(bootstrap.downloadURL)
        defer { try? fm.removeItem(at: tarball) }

        let size = (try? FileManager.default.attributesOfItem(atPath: tarball.path)[.size] as? Int) ?? nil
        if let size, size != bootstrap.expectedBytes {
            throw PulpieError.downloadFailed(
                bootstrap.downloadURL,
                underlying: "expected \(bootstrap.expectedBytes) bytes, got \(size) — truncated or wrong artifact")
        }

        let actual = try Self.sha256Hex(of: tarball)
        guard actual == bootstrap.sha256 else {
            throw PulpieError.checksumMismatch(expected: bootstrap.sha256, actual: actual)
        }

        // Unpack to a staging dir, then move into place, so an interrupted
        // unpack can never leave a half-populated model directory that the
        // "does it exist" check would happily accept.
        let staging = bootstrap.installDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".pulpie-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try Self.untar(tarball, into: staging)

        // The tarball contains a single top-level directory.
        let unpacked = staging.appendingPathComponent("pulpie-orange-small-coreml")
        var source = unpacked
        if !fm.fileExists(atPath: unpacked.path) {
            let entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            guard let only = entries.first, entries.count == 1 else {
                throw PulpieError.unpackFailed("expected one top-level directory, found \(entries.count)")
            }
            source = only
        }
        guard fm.fileExists(atPath: source.appendingPathComponent(PulpieModel.packageName).path) else {
            throw PulpieError.unpackFailed("archive did not contain \(PulpieModel.packageName)")
        }

        if fm.fileExists(atPath: bootstrap.installDirectory.path) {
            try fm.removeItem(at: bootstrap.installDirectory)
        }
        try fm.moveItem(at: source, to: bootstrap.installDirectory)
    }

    private static func download(_ url: URL) async throws -> URL {
        let fm = FileManager.default
        let destination = fm.temporaryDirectory
            .appendingPathComponent("pulpie-\(UUID().uuidString).tar.gz")

        if url.isFileURL {
            guard fm.fileExists(atPath: url.path) else {
                throw PulpieError.downloadFailed(url, underlying: "no such file")
            }
            try fm.copyItem(at: url, to: destination)
            return destination
        }

        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? fm.removeItem(at: temp)
                throw PulpieError.downloadFailed(url, underlying: "HTTP \(http.statusCode)")
            }
            try fm.moveItem(at: temp, to: destination)
            return destination
        } catch let error as PulpieError {
            throw error
        } catch {
            throw PulpieError.downloadFailed(url, underlying: error.localizedDescription)
        }
    }

    /// Streaming digest — the archive is ~730 MB and must not be read into memory.
    /// Internal so the bootstrap test can verify the configured artifact's
    /// digest independently, rather than trusting the same code path it is
    /// testing to have checked it.
    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func untar(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PulpieError.unpackFailed(
                String(data: errorData, encoding: .utf8) ?? "tar exited \(process.terminationStatus)")
        }
    }

    // MARK: Chunking

    struct Chunk {
        var tokens: [Int]
        var blockIndices: [Int]
    }

    /// Port of `pulpie.chunker.pack_chunks`.
    ///
    /// Layout per chunk: `[BOS] b0 <|sep|> b1 <|sep|> ... [EOS]`. Kept
    /// deliberately close to the Python so divergence is easy to spot; the
    /// oversized-block branch in particular is easy to get subtly wrong.
    static func packChunks(blockTokens: [[Int]]) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [Int] = []
        var currentIndices: [Int] = []
        var currentLength = 0

        // BOS and EOS are always emitted, so the usable budget is maxTokens - 2.
        let budget = Const.maxTokens - 2

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(
                Chunk(
                    tokens: [Const.bosTokenID] + current + [Const.eosTokenID],
                    blockIndices: currentIndices))
            current = []
            currentIndices = []
            currentLength = 0
        }

        for (blockIndex, tokens) in blockTokens.enumerated() {
            let cost = tokens.count + 1  // block + its <|sep|>

            if currentLength + cost > budget {
                flush()

                if cost > budget {
                    // A single block bigger than a whole chunk: truncate it,
                    // give it its own chunk, and move on. Reference truncates
                    // to `budget - 1` so the <|sep|> still fits.
                    let truncated = Array(tokens.prefix(budget - 1))
                    current = truncated + [Const.sepTokenID]
                    currentIndices = [blockIndex]
                    currentLength = truncated.count + 1
                    continue
                }
            }

            current += tokens
            current.append(Const.sepTokenID)
            currentIndices.append(blockIndex)
            currentLength += cost
        }
        flush()
        return chunks
    }

    // MARK: Inference

    /// One forward pass. Returns the raw `[sequenceLength * 2]` logits.
    static func infer(model: MLModel, tokens: [Int]) throws -> [Float] {
        let length = min(tokens.count, Const.sequenceLength)
        let shape: [NSNumber] = [1, NSNumber(value: Const.sequenceLength)]

        let inputIDs = try MLMultiArray(shape: shape, dataType: .int32)
        let attentionMask = try MLMultiArray(shape: shape, dataType: .int32)

        let idPointer = inputIDs.dataPointer.bindMemory(
            to: Int32.self, capacity: Const.sequenceLength)
        let maskPointer = attentionMask.dataPointer.bindMemory(
            to: Int32.self, capacity: Const.sequenceLength)
        for i in 0..<Const.sequenceLength {
            let real = i < length
            idPointer[i] = real ? Int32(tokens[i]) : Int32(Const.padTokenID)
            maskPointer[i] = real ? 1 : 0
        }

        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "attention_mask": MLFeatureValue(multiArray: attentionMask),
        ])
        let output = try model.prediction(from: features)

        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw PulpieError.badOutput("model produced no `logits` feature")
        }
        let expected = Const.sequenceLength * 2
        guard logits.count == expected else {
            throw PulpieError.badOutput("logits had \(logits.count) elements, expected \(expected)")
        }

        var result = [Float](repeating: 0, count: expected)
        switch logits.dataType {
        case .float32:
            let p = logits.dataPointer.bindMemory(to: Float.self, capacity: expected)
            result.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: p, count: expected) }
        case .double:
            let p = logits.dataPointer.bindMemory(to: Double.self, capacity: expected)
            for i in 0..<expected { result[i] = Float(p[i]) }
        case .float16:
            // Read through NSNumber rather than binding to Float16 so this
            // stays correct if a half-precision variant is swapped in.
            for i in 0..<expected { result[i] = logits[i].floatValue }
        default:
            throw PulpieError.badOutput("unsupported logits dtype \(logits.dataType.rawValue)")
        }
        return result
    }
}
