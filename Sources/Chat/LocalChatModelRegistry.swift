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
/// Today this is a hand-curated dictionary with one entry; Phase F.3 will add
/// a user-installed lane (HF URLs → ephemeral specs registered here at
/// runtime). The defaultModelName is what callers get when they don't pass an
/// explicit modelName — used by Pith, PithBackfill, and FriendRelay's local
/// branch so those paths keep working unchanged through the F.2-b refactor.
enum LocalChatModelRegistry {
    /// Lowest port handed out to a local chat model. Sits just above the
    /// embedding server (7712); leaves room for ~20 chat ports below the
    /// Sonata HTTP server's 7800 region. New registry entries take the next
    /// free port in this range.
    static let basePort = 7713

    /// Spec for a registry entry: the on-disk GGUF (via provisioner) plus the
    /// loopback port the server for this model is pinned to.
    struct Spec: Sendable {
        let modelName: String
        let binary: ManagedBinary
        let port: Int
    }

    /// Hardcoded registry. Order matters only for port assignment readability —
    /// the actual port is in each Spec, so reordering is safe as long as ports
    /// stay distinct.
    static let entries: [Spec] = [
        Spec(
            modelName: "llama-3.1-8b-instruct",
            binary: .llama31InstructModel,
            port: basePort  // 7713
        ),
    ]

    /// What callers get when they don't name a model. Today: the only entry.
    static let defaultModelName: String = entries[0].modelName

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
}
