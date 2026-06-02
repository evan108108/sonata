import Foundation
import Logging

/// Manages a local llama.cpp `llama-server` subprocess serving Llama 3.1 8B
/// Instruct — the local chat backend that powers pith L0/L1 generation (and
/// any future local-chat features). Sonata-internal plumbing, same shape as
/// `EmbeddingServerManager`; NOT a user-installed daemon.
///
/// Lazily started on first `chatCompletion(...)` call, so when no caller needs
/// chat this process never launches and the 4.6 GB model is never downloaded.
/// The binary + GGUF come from `BinaryProvisioner` (download-on-first-run);
/// the llama.cpp release binary runs in place beside its dylibs
/// (rpath @loader_path), so no DYLD wiring is needed.
actor ChatServerManager {
    static let shared = ChatServerManager()

    /// Loopback port for the local chat server. Embedding server uses 7712;
    /// app HTTP is 3211. Phase F.2 will turn this into a pool with one port
    /// per loaded model; today the singleton owns this port.
    static let defaultPort = 7713
    /// Public base URL — exposed for callers that want to redirect external
    /// tools (e.g. Claude Code via `ANTHROPIC_BASE_URL`) at the local server
    /// without hardcoding the port string. The trailing `/v1` is NOT included
    /// because consumers (OpenAI-compatible SDKs, Claude Code) append it.
    static let defaultBaseURL = "http://127.0.0.1:\(defaultPort)"
    /// Spawn-site prefix that tags a model as locally hosted. A model name
    /// starting with this is resolved to the local chat server and stripped
    /// before being passed to the runner as `--model <name>`.
    static let localModelPrefix = "local/"

    private let port = ChatServerManager.defaultPort
    private let logger: Logger
    private var process: Process?

    private var baseURL: String { "http://127.0.0.1:\(port)" }

    init() {
        var log = Logger(label: "sonata.chatserver")
        log.logLevel = .info
        self.logger = log
    }

    enum ChatError: Error {
        case binaryUnavailable
        case modelUnavailable
        case notHealthy
        case badResponse
        case missingContent
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Make a chat completion request against the locally-hosted model. Lazily
    /// ensures the server is up. Returns the assistant message content as a
    /// String — callers are responsible for parsing (e.g. JSON for pith).
    ///
    /// - Parameters:
    ///   - systemPrompt: the system message (frozen per use case)
    ///   - userContent: the user message
    ///   - maxTokens: max output tokens
    ///   - temperature: sampling temperature
    ///   - seed: random seed (llama.cpp honors it for reproducibility)
    ///   - jsonObject: if true, set `response_format: {type: "json_object"}` to
    ///     force server-side JSON-mode (Llama 3.1 still occasionally wraps in
    ///     markdown fences; callers should defensively strip).
    func chatCompletion(
        systemPrompt: String,
        userContent: String,
        maxTokens: Int = 400,
        temperature: Double = 0.3,
        seed: Int = 42,
        jsonObject: Bool = true
    ) async throws -> String {
        try await chatCompletionMessages(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            maxTokens: maxTokens,
            temperature: temperature,
            seed: seed,
            jsonObject: jsonObject
        )
    }

    /// Multi-turn variant: pass the full messages array verbatim. Use this when
    /// the caller has its own conversation history (e.g. FriendRelay replying
    /// in an email thread where prior turns matter).
    ///
    /// Each message must be `["role": <system|user|assistant>, "content": ...]`.
    func chatCompletionMessages(
        messages: [[String: String]],
        maxTokens: Int = 400,
        temperature: Double = 0.3,
        seed: Int = 42,
        jsonObject: Bool = false
    ) async throws -> String {
        try await ensureRunning()

        var body: [String: Any] = [
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "seed": seed,
        ]
        if jsonObject {
            body["response_format"] = ["type": "json_object"]
        }

        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw ChatError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ChatError.notHealthy
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ChatError.badResponse
        }
        return content
    }

    /// Provision (download on first run) + launch + health-check. Idempotent.
    func ensureRunning() async throws {
        if isRunning { return }

        guard let binary = await BinaryProvisioner.shared.provision(.llamaServer) else {
            throw ChatError.binaryUnavailable
        }
        guard let model = await BinaryProvisioner.shared.provision(.llama31InstructModel) else {
            throw ChatError.modelUnavailable
        }

        killOrphans()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-m", model,
            "--host", "127.0.0.1", "--port", "\(port)",
            "--ctx-size", "8192",
            "--n-predict", "400",
            "--temp", "0.3",
            // Push all layers to GPU. Apple Silicon Metal handles 8B Q4 easily;
            // CPU-only would be 10x slower.
            "-ngl", "99",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc

        // Loading a 4.6 GB GGUF + warming Metal takes longer than embeddings; give it 60s.
        guard await waitForHealthy(timeoutSeconds: 60) else {
            logger.error("llama-server (chat) failed health check on port \(port)")
            process = nil
            throw ChatError.notHealthy
        }
        logger.info("chat server up (pid \(proc.processIdentifier), port \(port))")
    }

    func shutdown() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
    }

    // MARK: - Internals

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

    /// Kill any orphaned chat server on our port from a prior run.
    private func killOrphans() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "llama-server.*--port \(port)"]
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
