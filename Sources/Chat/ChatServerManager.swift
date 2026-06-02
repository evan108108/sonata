import Foundation
import Logging

/// Pooled manager for local `llama-server` subprocesses — one process per
/// distinct model in `LocalChatModelRegistry`. Phase F.2-b: was previously a
/// singleton that only knew about Llama 3.1 8B; now keyed by `modelName` so a
/// session on Llama can coexist with (future) sessions on Qwen / Falcon /
/// user-installed GGUFs without sharing process state.
///
/// Within a single process, `--parallel 2 -cb` (set in the spawn args below)
/// gives us continuous-batching multiplexing — pith and an interactive
/// session sharing the SAME model interleave decode steps instead of queueing.
/// That fix is independent of pooling: per-model pooling is for *different*
/// model contention; per-process parallel is for *same-model* contention.
///
/// All public methods take an optional `modelName` defaulting to
/// `LocalChatModelRegistry.defaultModelName` so existing callers (Pith,
/// PithBackfill, FriendRelay's local branch) keep working without touching
/// their call sites — they implicitly use Llama 3.1 8B as before.
actor ChatServerManager {
    static let shared = ChatServerManager()

    /// Spawn-site prefix that tags a model as locally hosted. A model name
    /// starting with this is resolved to the local chat server and stripped
    /// before being passed to the runner as `--model <name>`.
    static let localModelPrefix = "local/"

    /// Backward-compat alias for spawn-sites written before the registry
    /// existed. Resolves to the URL of the default model's server. New code
    /// should call `LocalChatModelRegistry.baseURL(for:)` with an explicit
    /// modelName so a non-default model picker actually points the redirect
    /// at the right port.
    static var defaultBaseURL: String {
        LocalChatModelRegistry.baseURL(for: LocalChatModelRegistry.defaultModelName)
    }

    private let logger: Logger
    private var processes: [String: Process] = [:]

    init() {
        var log = Logger(label: "sonata.chatserver")
        log.logLevel = .info
        self.logger = log
    }

    enum ChatError: Error {
        case unknownModel(String)
        case binaryUnavailable
        case modelUnavailable
        case notHealthy
        case badResponse
        case missingContent
    }

    func isRunning(modelName: String = LocalChatModelRegistry.defaultModelName) -> Bool {
        processes[modelName]?.isRunning == true
    }

    /// Single-turn convenience. Builds a [system, user] messages array and
    /// forwards to `chatCompletionMessages`.
    ///
    /// - Parameters:
    ///   - modelName: which local model to hit. Defaults to the registry's
    ///     default (Llama 3.1 8B today) — keeps existing callsites unchanged.
    ///   - systemPrompt: the system message (frozen per use case)
    ///   - userContent: the user message
    ///   - maxTokens: max output tokens
    ///   - temperature: sampling temperature
    ///   - seed: random seed (llama.cpp honors it for reproducibility)
    ///   - jsonObject: if true, set `response_format: {type: "json_object"}` to
    ///     force server-side JSON-mode (Llama 3.1 still occasionally wraps in
    ///     markdown fences; callers should defensively strip).
    func chatCompletion(
        modelName: String = LocalChatModelRegistry.defaultModelName,
        systemPrompt: String,
        userContent: String,
        maxTokens: Int = 400,
        temperature: Double = 0.3,
        seed: Int = 42,
        jsonObject: Bool = true
    ) async throws -> String {
        try await chatCompletionMessages(
            modelName: modelName,
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
        modelName: String = LocalChatModelRegistry.defaultModelName,
        messages: [[String: String]],
        maxTokens: Int = 400,
        temperature: Double = 0.3,
        seed: Int = 42,
        jsonObject: Bool = false
    ) async throws -> String {
        try await ensureRunning(modelName: modelName)

        var body: [String: Any] = [
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "seed": seed,
        ]
        if jsonObject {
            body["response_format"] = ["type": "json_object"]
        }

        let baseURL = LocalChatModelRegistry.baseURL(for: modelName)
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

    /// Provision (download on first run) + launch + health-check the server
    /// for `modelName`. Idempotent: returns immediately if the process for
    /// this model is already up. Each modelName owns its own port from the
    /// registry — two distinct models means two distinct processes on two
    /// distinct ports, no contention.
    func ensureRunning(modelName: String = LocalChatModelRegistry.defaultModelName) async throws {
        if isRunning(modelName: modelName) { return }

        guard let spec = LocalChatModelRegistry.spec(for: modelName) else {
            throw ChatError.unknownModel(modelName)
        }
        guard let binary = await BinaryProvisioner.shared.provision(.llamaServer) else {
            throw ChatError.binaryUnavailable
        }
        guard let model = await BinaryProvisioner.shared.provision(spec.binary) else {
            throw ChatError.modelUnavailable
        }

        let port = spec.port
        killOrphans(port: port)

        // Two env knobs control the server's runtime budget so the user can
        // tune for the active workload without a code change:
        //
        //   SONA_CHAT_PARALLEL (default 1) — concurrent request slots.
        //     1 = no multiplexing overhead, best throughput for a single
        //         client (PithBackfill running alone, the common case).
        //     2+ = continuous-batching for interactive Claude Code sessions
        //         that would otherwise queue behind pith. Costs ~50%
        //         throughput-when-alone for zero contention.
        //
        //   SONA_CHAT_CTX_PER_SLOT (default 8192) — context window per slot.
        //     8192 = pith-sized. Tiny KV cache, fastest per-request scheduling.
        //         Default while the big NULL-l0/l1 backfill is the dominant
        //         workload; Claude Code workers/sessions will reject inbound
        //         requests at this size (their system prompt is >100K tokens).
        //     131072 = Llama 3.1's native context. Required for Claude Code
        //         worker/session redirect to actually work end-to-end. Bump
        //         to this when the backfill is done and you want to chat
        //         with a local model.
        //
        // Total --ctx-size = perSlot × parallel (llama-server divides ctx
        // evenly across slots, and each slot must hold a full request).
        let parallel = max(1, Int(ProcessInfo.processInfo.environment["SONA_CHAT_PARALLEL"] ?? "1") ?? 1)
        let perSlotCtx = max(2048, Int(ProcessInfo.processInfo.environment["SONA_CHAT_CTX_PER_SLOT"] ?? "8192") ?? 8192)
        let totalCtx = perSlotCtx * parallel

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-m", model,
            "--host", "127.0.0.1", "--port", "\(port)",
            "--ctx-size", "\(totalCtx)",
            "--parallel", "\(parallel)",
            "-cb",
            "--n-predict", "400",
            "--temp", "0.3",
            // Push all layers to GPU. Apple Silicon Metal handles 8B Q4 easily;
            // CPU-only would be 10x slower.
            "-ngl", "99",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        processes[modelName] = proc

        // Loading a 4.6 GB GGUF + warming Metal takes longer than embeddings; give it 60s.
        guard await waitForHealthy(port: port, timeoutSeconds: 60) else {
            logger.error("llama-server (chat) failed health check for \(modelName) on port \(port)")
            processes[modelName] = nil
            throw ChatError.notHealthy
        }
        logger.info("chat server up: \(modelName) (pid \(proc.processIdentifier), port \(port))")
    }

    /// Terminate every running chat-server process this manager owns.
    /// Used on app shutdown; per-model shutdown isn't surfaced yet because
    /// no caller needs it. Idle-shutdown is deferred until multiple models
    /// are commonly in flight at once.
    func shutdownAll() {
        for (modelName, proc) in processes where proc.isRunning {
            proc.terminate()
            processes[modelName] = nil
        }
    }

    // MARK: - Internals

    private func waitForHealthy(port: Int, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let url = URL(string: "http://127.0.0.1:\(port)/health") {
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

    /// Kill any orphaned chat server on the given port from a prior run.
    /// Scoped per port so we don't terminate a sibling model's process.
    private func killOrphans(port: Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "llama-server.*--port \(port)"]
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
