import Foundation
import Logging

/// Manages a local llama.cpp `llama-server --embedding` subprocess serving
/// EmbeddingGemma-300m — the local embedding backend that replaces the remote
/// OpenRouter embedding API. Sonata-internal plumbing, same pattern as
/// `MeiliSearchManager`; NOT a user-installed daemon.
///
/// Lazily started on first `embed(...)` call, so when the OpenRouter provider is
/// selected this process never launches and the model is never downloaded. The
/// binary + GGUF come from `BinaryProvisioner` (download-on-first-run); the
/// llama.cpp release binary runs in place beside its dylibs (rpath @loader_path),
/// so no DYLD wiring is needed.
actor EmbeddingServerManager {
    static let shared = EmbeddingServerManager()

    private let port = 7712            // MeiliSearch uses 7711; the app's HTTP API is 3211
    private let logger: Logger
    private var process: Process?

    private var baseURL: String { "http://127.0.0.1:\(port)" }

    init() {
        var log = Logger(label: "sonata.embeddingserver")
        log.logLevel = .info
        self.logger = log
    }

    enum EmbeddingError: Error { case binaryUnavailable, modelUnavailable, notHealthy, badResponse }

    var isRunning: Bool { process?.isRunning == true }

    /// Embed `text` via the local server, prepending EmbeddingGemma's required task
    /// prompt (`task: search result | query: ` for queries, `title: none | text: `
    /// for corpus). Lazily ensures the server is up. Returns a 768-dim L2-normalized
    /// vector.
    func embed(_ text: String, isQuery: Bool) async throws -> [Float] {
        try await ensureRunning()
        let prefix = isQuery ? "task: search result | query: " : "title: none | text: "
        // EmbeddingGemma's context is 2048 tokens; clip very long inputs to a safe
        // char budget so they embed in one pass instead of 500'ing. Dense text
        // (code, punctuation) runs ~2.5 chars/token, so 4000 chars stays under 2048
        // even at worst case. Only a handful of memories exceed this; the head
        // captures the gist. (Must match reembed-gemma.mjs MAXCHARS.)
        let clipped = text.count > Self.maxInputChars ? String(text.prefix(Self.maxInputChars)) : text
        return try await requestEmbedding(prefix + clipped)
    }

    private static let maxInputChars = 4000

    /// Provision (download on first run) + launch + health-check. Idempotent.
    func ensureRunning() async throws {
        if isRunning { return }

        guard let binary = await BinaryProvisioner.shared.provision(.llamaServer) else {
            throw EmbeddingError.binaryUnavailable
        }
        guard let model = await BinaryProvisioner.shared.provision(.embeddingGemmaModel) else {
            throw EmbeddingError.modelUnavailable
        }

        killOrphans()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-m", model,
            "--embedding", "--pooling", "mean",
            "--host", "127.0.0.1", "--port", "\(port)",
            "--ctx-size", "2048",
            // EmbeddingGemma is trained at a 2048-token context. Physical batch must
            // hold a whole pooled sequence in one pass — the default (512) makes
            // llama-server 500 on any input over ~512 tokens ("input too large to
            // process"), so longer memories would silently fail to embed and fall
            // back to keyword. Match ctx so any single doc/query up to the context
            // window embeds in one shot (inputs are clipped to fit in `embed`).
            "--batch-size", "2048", "--ubatch-size", "2048",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc

        guard await waitForHealthy(timeoutSeconds: 30) else {
            logger.error("llama-server (embeddings) failed health check on port \(port)")
            process = nil
            throw EmbeddingError.notHealthy
        }
        logger.info("embedding server up (pid \(proc.processIdentifier), port \(port))")
    }

    func shutdown() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
    }

    /// Synchronous shutdown for `willTerminate`. Internal model — always
    /// pkilled on app quit whether we spawned it or adopted an orphan from
    /// a prior run. Port is hardcoded (7712).
    nonisolated static func terminateOnQuit() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "llama-server.*--port 7712"]
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - HTTP

    private func requestEmbedding(_ input: String) async throws -> [Float] {
        guard let url = URL(string: "\(baseURL)/v1/embeddings") else { throw EmbeddingError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["input": input, "model": "embeddinggemma-300m"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw EmbeddingError.notHealthy }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]],
              let emb = arr.first?["embedding"] as? [Any] else {
            throw EmbeddingError.badResponse
        }
        return emb.compactMap { ($0 as? NSNumber)?.floatValue }
    }

    private func waitForHealthy(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let url = URL(string: "\(baseURL)/health") {
                var req = URLRequest(url: url)
                req.timeoutInterval = 2
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Kill any orphaned embedding server on our port from a prior run.
    private func killOrphans() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "llama-server.*--port \(port)"]
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
