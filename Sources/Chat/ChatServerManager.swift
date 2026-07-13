import Foundation
import Logging
import os

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

    private let logger: Logging.Logger
    private var processes: [String: Process] = [:]

    /// Ports of user-installed models we have spawned in this app run.
    /// Maintained alongside `processes` so the synchronous `terminateOnQuit`
    /// (called from `NSApplication.willTerminateNotification` which has no
    /// async budget) can pkill exactly the user-installed servers Sonata
    /// started — adopted orphans stay running. Hardcoded internal models are
    /// killed unconditionally by terminateOnQuit and don't appear here.
    private static let spawnedUserModelPorts = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    init() {
        var log = Logging.Logger(label: "sonata.chatserver")
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

        // Orphan adoption: after a Sonata restart, the actor's `processes`
        // dict is empty even though llama-server orphans from the prior run
        // are still bound to their ports and serving requests. Before doing
        // anything destructive, probe /health — if a healthy server is
        // already listening on the model's port, treat the request as
        // fulfilled. The previous behavior (killOrphans → spawn → wait 60s)
        // was needlessly killing the working orphan on every deploy, which
        // in turn made pith calls fail with notHealthy for the ~30-60s it
        // took the fresh spawn to come up (or worse, when the fresh spawn
        // hit memory pressure from a sibling model and couldn't bind at all).
        //
        // Per-call probe (no caching): if the orphan dies, the next call
        // falls through to the spawn path. ~50-200ms probe latency is fine
        // for pith call volume.
        if await waitForHealthy(port: spec.port, timeoutSeconds: 1) {
            logger.info("adopted existing llama-server on port \(spec.port) for \(modelName)")
            return
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
        //   SONA_CHAT_CTX_PER_SLOT (default 131072) — context window per slot.
        //     131072 = Llama 3.1's native context. Required for Claude Code
        //         worker/session redirect (system prompt + tools + skills is
        //         100K+ tokens). Empirically ALSO faster for pith on Apple
        //         Silicon — Metal kernels are tuned for larger ctx and slow
        //         down at small sizes; counterintuitively, 8192 measured
        //         ~5× slower than 131072 for the same single-shot pith load.
        //         So the only reason to lower this is RAM pressure, not speed.
        //     8192 = minimal KV cache (~32MB extra). Use only on memory-
        //         constrained machines where you don't need Claude Code
        //         worker support. Pith still works but slower per request.
        //
        // Total --ctx-size = perSlot × parallel (llama-server divides ctx
        // evenly across slots, and each slot must hold a full request).
        let parallel = max(1, Int(ProcessInfo.processInfo.environment["SONA_CHAT_PARALLEL"] ?? "1") ?? 1)
        // Default ctx scales with installed RAM. 128K ctx at -ngl 99 on a 16 GB
        // Mac drives Metal into kIOGPUCommandBufferCallbackErrorOutOfMemory
        // (Scout, 2026-06-22 — wedged the backend and turned PithBackfill into
        // a hot retry loop that filled the log to 297 MB in ~3 minutes). 32 GB
        // tier gets a middle setting; 64 GB+ keeps the native max. The env var
        // remains the explicit override (used in the Scout Info.plist fix).
        let gigaByte: UInt64 = 1024 * 1024 * 1024
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        let defaultCtx: Int
        if ramBytes <= 17 * gigaByte {
            defaultCtx = 8192
        } else if ramBytes <= 33 * gigaByte {
            defaultCtx = 32768
        } else {
            defaultCtx = 131072
        }
        let perSlotCtx = max(2048, Int(ProcessInfo.processInfo.environment["SONA_CHAT_CTX_PER_SLOT"] ?? "\(defaultCtx)") ?? defaultCtx)
        let totalCtx = perSlotCtx * parallel

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        var args: [String] = [
            "-m", model,
            "--host", "127.0.0.1", "--port", "\(port)",
            "--ctx-size", "\(totalCtx)",
            "--parallel", "\(parallel)",
            "-cb",
            "--n-predict", "400",
            "--temp", "0.3",
            // Cold prompt-eval tuning. Claude Code's first request to a fresh
            // local server ships 100K+ tokens of system prompt + tool defs +
            // skills; ingesting that at default settings takes ~17 min on M-
            // series. The four args below cut that to ~9-12 min cumulatively.
            //
            // -fa on: fused flash-attention kernels. Metal-specific speedup on
            //   both prompt-eval and decode for any non-trivial context. Newer
            //   llama.cpp builds (>= b9270) require the explicit on|off|auto
            //   value — bare `-fa` silently consumes the next arg and aborts
            //   server boot with "unknown value for --flash-attn: '-b'".
            // -b 4096 / -ub 2048: larger logical/physical batch sizes for
            //   prompt-eval. Default is 2048/512 — the bigger batches saturate
            //   Metal's matmul kernels better on long ingest. Trade: brief RAM
            //   spike during prompt eval, irrelevant on 16GB+ unified memory.
            // --cache-type-k/v q8_0: quantize KV cache to int8 (default f16).
            //   Halves KV cache RAM and speeds up attention reads. Quality
            //   loss is undetectable at Q4 model weights — the model's own
            //   weights are already quantized harder than the cache.
            "-fa", "on",
            "-b", "4096", "-ub", "2048",
            "--cache-type-k", "q8_0",
            "--cache-type-v", "q8_0",
            // Push all layers to GPU. Apple Silicon Metal handles 8B Q4 easily;
            // CPU-only would be 10x slower.
            "-ngl", "99",
        ]
        // Per-model extras (F.3+): YaRN/RoPE scaling for Qwen, special chat
        // templates, etc. Empty for built-in entries; populated from the
        // user-installed row's `extraArgs` column for installed models.
        args.append(contentsOf: spec.extraSpawnArgs)
        proc.arguments = args

        // Capture llama-server stderr to a per-model log so silent failures
        // (e.g. n_ctx clamped to the trained context when YaRN isn't on,
        // unknown-flag aborts, OOM warnings) are debuggable. stdout stays
        // discarded — the useful boot + warning output goes to stderr.
        //
        // Two guards keep this log from growing without bound. A runaway copy
        // filled the Scout machine's disk to 0.3 GB free in June 2026: an
        // erroring server spewed to a stderr log that had no cap, and because
        // the handle below used to seekToEndOfFile() on a plain FileHandle, an
        // out-of-band truncation (cleanup cron / `: > log`) left the server
        // writing at its old multi-GB offset, re-inflating the file as a
        // *sparse* 100+ GB ghost. The fixes, mirroring
        // installSonataStdoutRedirect():
        //   1. O_APPEND instead of seek-to-end. O_APPEND repositions to true
        //      EOF on every write, so out-of-band truncation reclaims space
        //      cleanly instead of going sparse.
        //   2. Boot-time rotation: if the existing log is over the cap, move it
        //      aside to <log>.1 (overwriting any prior rotation) and start
        //      fresh, bounding growth across restarts.
        let stderrPath = Self.logURL(for: modelName).path
        try? FileManager.default.createDirectory(
            atPath: (stderrPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let logRotateCapBytes: UInt64 = 200 * 1024 * 1024
        let existingLogSize = (try? FileManager.default.attributesOfItem(atPath: stderrPath))
            .flatMap { ($0[.size] as? NSNumber)?.uint64Value } ?? 0
        if existingLogSize > logRotateCapBytes {
            let rotated = stderrPath + ".1"
            try? FileManager.default.removeItem(atPath: rotated)
            try? FileManager.default.moveItem(atPath: stderrPath, toPath: rotated)
        }
        let stderrFD = open(stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if stderrFD >= 0 {
            proc.standardError = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: true)
        } else {
            proc.standardError = FileHandle.nullDevice
        }
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        processes[modelName] = proc
        let isHardcoded = LocalChatModelRegistry.hardcoded.contains { $0.modelName == modelName }
        if !isHardcoded {
            Self.spawnedUserModelPorts.withLock { _ = $0.insert(port) }
        }

        // Loading a 4.6 GB GGUF + warming Metal takes longer than embeddings; give it 60s.
        guard await waitForHealthy(port: port, timeoutSeconds: 60) else {
            logger.error("llama-server (chat) failed health check for \(modelName) on port \(port)")
            processes[modelName] = nil
            throw ChatError.notHealthy
        }
        logger.info("chat server up: \(modelName) (pid \(proc.processIdentifier), port \(port))")
    }

    /// Terminate every running chat-server process this manager owns.
    /// Used on app shutdown.
    func shutdownAll() {
        for (modelName, proc) in processes where proc.isRunning {
            proc.terminate()
            processes[modelName] = nil
        }
        Self.spawnedUserModelPorts.withLock { $0.removeAll() }
    }

    /// Terminate the server for a single model. Called by
    /// `InstalledChatModelManager.uninstall` so a deleted GGUF isn't being
    /// held by a stale process. No-op when the server isn't running.
    func shutdown(modelName: String) {
        let port = LocalChatModelRegistry.spec(for: modelName)?.port
        guard let proc = processes[modelName], proc.isRunning else {
            processes[modelName] = nil
            if let port = port {
                Self.spawnedUserModelPorts.withLock { _ = $0.remove(port) }
            }
            return
        }
        proc.terminate()
        processes[modelName] = nil
        if let port = port {
            Self.spawnedUserModelPorts.withLock { _ = $0.remove(port) }
        }
        logger.info("chat server terminated: \(modelName)")
    }

    /// Synchronous shutdown for the app-quit (`willTerminate`) path. macOS
    /// gives willTerminate a ~5s budget before SIGKILL, and the handler runs
    /// on the main thread — so we can't `await` the actor. Instead:
    ///   - Hardcoded internal models (Llama 3.1 8B pith, etc.): pkill the
    ///     port unconditionally. These are "ours" regardless of whether we
    ///     spawned the live process or adopted an orphan from a prior run.
    ///   - User-installed models: pkill ONLY the ports we ourselves spawned
    ///     this run (tracked in `spawnedUserModelPorts`). Adopted orphans
    ///     stay running — if the user installed a model and an orphan from
    ///     a prior run is still serving it, we don't claim ownership.
    nonisolated static func terminateOnQuit() {
        for spec in LocalChatModelRegistry.hardcoded {
            pkillPort(spec.port)
        }
        let ports = spawnedUserModelPorts.withLock { state -> Set<Int> in
            let snapshot = state
            state.removeAll()
            return snapshot
        }
        for port in ports {
            pkillPort(port)
        }
    }

    private nonisolated static func pkillPort(_ port: Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "llama-server.*--port \(port)"]
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
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

    /// Per-model stderr log location. Files live under `~/.sonata/logs/` so
    /// the Sonata app log directory stays clean and users can grep / tail one
    /// model without noise from siblings. Filenames sanitize the modelName
    /// to a filesystem-safe form (the registry already enforces a strict
    /// charset, so this is paranoia, not real escaping).
    static func logURL(for modelName: String) -> URL {
        let dir = URL(fileURLWithPath: SonataInstance.dataDirectory)
            .appendingPathComponent("logs", isDirectory: true)
        let safe = modelName.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("llama-\(safe).log")
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
