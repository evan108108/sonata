import Foundation

/// Source of truth for the local chat models Sonata knows how to host.
///
/// A "local chat model" is identified by a short stable name (the same string
/// Claude Code is passed via `--model`, and that the spawn-site appends after
/// the `local/` prefix when building a Worker / InteractiveSessionTab).
///
/// Each entry pins:
///   - the `BinaryProvisioner.ManagedBinary` whose GGUF backs this model
///   - a *deterministic* loopback port so spawn-sites can compute the redirect
///     URL synchronously without awaiting the actor
///
/// Two lanes:
///   - `hardcoded`: ships with Sonata, one entry today (Llama 3.1 8B). Pinned
///     at compile time.
///   - `userInstalled`: hydrated at boot from the v22 `installedChatModels`
///     table (Phase F.3). User adds entries via Settings → Local Models;
///     `InstalledChatModelManager` writes to the table and calls `replaceUserInstalled`
///     to refresh the in-memory list. New entries auto-appear in the worker
///     and session model pickers.
///
/// The defaultModelName is what callers get when they don't pass an explicit
/// modelName — used by Pith, PithBackfill, and FriendRelay's local branch so
/// those paths keep working unchanged through the F.2-b refactor.
enum LocalChatModelRegistry {
    /// Lowest port handed out to a local chat model. Sits just above the
    /// embedding server (7712); leaves room for ~20 chat ports below the
    /// Sonata HTTP server's 7800 region. New registry entries take the next
    /// free port in this range.
    static let basePort = 7713

    /// Spec for a registry entry: the on-disk GGUF (via provisioner) plus the
    /// loopback port the server for this model is pinned to. `displayName` is
    /// the UI-friendly label; equals `modelName` for hardcoded entries that
    /// didn't bother spelling out a longer string. `extraSpawnArgs` are
    /// appended to the llama-server argv at spawn time — used for per-model
    /// quirks llama-server can't infer from the GGUF metadata (RoPE scaling,
    /// non-default chat templates, etc.).
    struct Spec: Sendable {
        let modelName: String
        let displayName: String
        let binary: ManagedBinary
        let port: Int
        let extraSpawnArgs: [String]
    }

    /// Hardcoded registry. Order matters only for port assignment readability —
    /// the actual port is in each Spec, so reordering is safe as long as ports
    /// stay distinct.
    static let hardcoded: [Spec] = [
        Spec(
            modelName: "llama-3.1-8b-instruct",
            displayName: "Llama 3.1 8B Instruct (built-in)",
            binary: .llama31InstructModel,
            port: basePort,  // 7713
            extraSpawnArgs: []
        ),
    ]

    /// User-installed entries, hydrated at boot from `installedChatModels`
    /// rows by `replaceUserInstalled`. Empty until then.
    ///
    /// nonisolated(unsafe) is fine here: replaceUserInstalled is called once
    /// at app boot from SonataApp's launch Task (single writer), and readers
    /// (spawn-sites, ChatServerManager) only read. No tearing in practice; if
    /// dynamic add/remove ever needs to be concurrent with reads, wrap this
    /// in an actor.
    nonisolated(unsafe) static var userInstalled: [Spec] = []

    /// All entries — hardcoded first, then user-installed in install order.
    /// UI pickers iterate this so new installs auto-appear.
    static var entries: [Spec] { hardcoded + userInstalled }

    /// What callers get when they don't name a model. Today: the first
    /// hardcoded entry (Llama 3.1 8B). Stays stable even as users install
    /// additional models — Pith/PithBackfill/FriendRelay keep using the same
    /// default without surprise.
    static let defaultModelName: String = hardcoded[0].modelName

    /// Quick lookup. Returns nil for an unknown name; callers should treat
    /// that as a hard error since spawn-sites only see names that came out of
    /// the same registry (UI picker / persistence column).
    static func spec(for modelName: String) -> Spec? {
        entries.first { $0.modelName == modelName }
    }

    /// Synchronous URL for the model's loopback server. Spawn-sites use this
    /// to set ANTHROPIC_BASE_URL at process-build time, *before* the actor's
    /// ensureRunning(modelName:) call has resolved — the port mapping is
    /// fixed at compile time so we don't need the server to be live to know
    /// where it will be.
    static func baseURL(for modelName: String) -> String {
        let port = spec(for: modelName)?.port ?? basePort
        return "http://127.0.0.1:\(port)"
    }

    /// Replace the user-installed list. Called by InstalledChatModelManager
    /// at boot (after reading the DB) and after each install/delete.
    static func replaceUserInstalled(_ specs: [Spec]) {
        userInstalled = specs
    }
}
