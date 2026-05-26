import Foundation

// MARK: - Worker Engine (no-fork Goose binding, T3)
//
// Sonata's default agent engine is Anthropic's Claude Code; this file adds
// Block's **Goose** (github.com/block/goose, pinned 1.35.0) as a *selectable*
// alternative — Claude Code stays the default, the engine is chosen per
// worker/session. NO FORK: Goose is driven through its stock CLI exactly the
// way `WorkerCoordinator` shells `claude`; only the flag strings and the
// wake-prompt framing differ. Report-back + skills are delivered as Goose MCP
// extensions (the channels server / skills-loader built under
// /Users/evan/memory/goose). See claude/documents/plans/goose-no-fork-engine-plan.md
// §3.iii and wiki sonata/goose-engine.

/// Which agent engine backs a worker session.
enum WorkerEngine: String, Sendable, CaseIterable {
    case claude
    case goose

    /// Parse a raw engine string (UI / env / future DB column), defaulting to
    /// `.claude` for nil/blank/unknown so existing behavior never changes.
    static func from(_ raw: String?) -> WorkerEngine {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              let engine = WorkerEngine(rawValue: raw)
        else { return .claude }
        return engine
    }

    /// Process-wide default engine for newly spawned workers. Claude unless
    /// `SONA_WORKER_ENGINE` overrides it — keeps Goose strictly opt-in.
    static var defaultEngine: WorkerEngine {
        from(ProcessInfo.processInfo.environment["SONA_WORKER_ENGINE"])
    }
}

/// Thin, no-fork binding from Sonata's worker lifecycle (`spawn` / `wake` /
/// `resume`) onto the stock Goose CLI. Pure argv/env construction — no process
/// side effects — so it is fully unit-testable without launching `goose`.
/// Mirrors `WorkerManager.claudeBinary` + `WorkerCoordinator.startProcess`.
enum GooseEngineBinding {
    /// Resolve the `goose` binary, mirroring `WorkerManager.claudeBinary`.
    /// `SONA_GOOSE_BINARY` overrides; otherwise the usual install locations.
    static func binary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        fileManager: FileManager = .default
    ) -> String {
        if let override = env["SONA_GOOSE_BINARY"], !override.isEmpty {
            return override
        }
        let resolvedHome = home ?? env["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "\(resolvedHome)/.local/bin/goose",
            "/opt/homebrew/bin/goose",
            "/usr/local/bin/goose",
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        return "goose"
    }

    /// argv for the persistent interactive PTY session — the spawn analog of a
    /// long-lived `claude` worker. `--name` sets a durable session name so
    /// restart-recovery resumes the same conversation (the Goose equivalent of
    /// Claude Code `--session-id`; `goose run` also accepts `--session-id`, but
    /// `session --name` is the interactive entry point). Goose has no
    /// channel-self-poll flag (Claude's `--dangerously-load-development-channels`)
    /// — report-back + skills arrive via the MCP extensions in `extensionArgs`.
    static func spawnArgs(sessionId: String, extensionArgs: [String] = []) -> [String] {
        var args = ["session", "--name", sessionId]
        args.append(contentsOf: extensionArgs)
        return args
    }

    /// argv for a headless wake/resume that injects one event as the prompt —
    /// the direct analog of Claude Code `--resume --session-id`. Spawned by the
    /// adapter when an event is dispatched to an idle Goose session: it
    /// rehydrates from Goose's SQLite sessions DB, runs one turn, then exits.
    /// (Live wiring of "event dispatched → spawn this" is the T4 e2e step.)
    static func wakeArgs(sessionId: String, eventPrompt: String, extensionArgs: [String] = []) -> [String] {
        var args = ["run", "--resume", "--name", sessionId, "--text", eventPrompt]
        args.append(contentsOf: extensionArgs)
        return args
    }

    /// `--with-extension "<stdio command>"` args that attach the Sonata
    /// channels (report-back, T2) and skills-loader (Claude `SKILL.md`, T1) MCP
    /// servers to a Goose invocation **without touching the user's global
    /// ~/.config/goose/config.yaml**. Server paths + runner are env-overridable;
    /// defaults point at the built servers under `~/memory/goose`. Only servers
    /// that actually exist on disk are attached (graceful when unbuilt).
    static func extensionArgs(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        let resolvedHome = home ?? env["HOME"] ?? NSHomeDirectory()
        let runner = env["SONA_GOOSE_MCP_RUNNER"] ?? "bun"
        let channels = env["SONA_GOOSE_CHANNELS_SERVER"]
            ?? "\(resolvedHome)/memory/goose/channels/server.ts"
        let skills = env["SONA_GOOSE_SKILLS_SERVER"]
            ?? "\(resolvedHome)/memory/goose/skills-loader/server.ts"
        var args: [String] = []
        for server in [channels, skills] where fileManager.fileExists(atPath: server) {
            args.append(contentsOf: ["--with-extension", "\(runner) \(server)"])
        }
        return args
    }

    /// Engine-specific environment additions. `GOOSE_MODE=auto` is the
    /// non-interactive auto-approve mode — the analog of Claude Code's
    /// `--dangerously-skip-permissions` so a worker never blocks on a tool
    /// prompt (verified: Goose 1.35.0's sessions DB stores
    /// `goose_mode TEXT NOT NULL DEFAULT 'auto'`). Provider/model come from env
    /// (`SONA_GOOSE_PROVIDER` / `SONA_GOOSE_MODEL`, falling back to Goose's own
    /// `GOOSE_PROVIDER` / `GOOSE_MODEL`); never hardcoded — if unset, Goose
    /// reads its config.yaml. Anthropic creds already flow via the worker env
    /// passthrough (`ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`).
    static func envAdditions(
        skipPermissions: Bool,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var additions: [String] = []
        if skipPermissions {
            additions.append("GOOSE_MODE=auto")
        }
        if let provider = env["SONA_GOOSE_PROVIDER"] ?? env["GOOSE_PROVIDER"], !provider.isEmpty {
            additions.append("GOOSE_PROVIDER=\(provider)")
        }
        if let model = env["SONA_GOOSE_MODEL"] ?? env["GOOSE_MODEL"], !model.isEmpty {
            additions.append("GOOSE_MODEL=\(model)")
        }
        return additions
    }
}
