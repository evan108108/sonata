import Foundation

/// Resolves the Claude Code binary Sonata should spawn.
///
/// This lived duplicated in four places — `InteractiveSessionsViewModel`,
/// `WorkersView`, `SidecarSpawner`, `SupervisorTerminalView` — and they
/// drifted: two had a bare `SONA_CLAUDE_BINARY ?? ~/.local/bin/claude`
/// fallback, the other two had a longer candidate list. Neither variant
/// checked `~/bin/claude-patched`, so the nightly-built patched binary
/// (the one the user's `sona` shell function invokes) never actually ran
/// under Sonata's own worker/spawn paths. Channels stayed working only
/// because Anthropic kept `tengu_harbor` returning ON server-side;
/// the day they returned it OFF (2026-06-23), fleets on stock lost
/// channels silently. This helper is the single source of truth so that
/// drift can't recur.
enum ClaudeBinary {
    /// The path Sonata should exec for Claude Code. Deterministic — the
    /// first entry in the priority list that is executable wins. Priority:
    ///
    /// 1. `SONA_CLAUDE_BINARY` in the process environment (explicit override).
    /// 2. `~/bin/claude-patched` — Sona's nightly-patched build (channel
    ///    gates flipped ON regardless of Anthropic's server flag).
    /// 3. `~/.local/bin/claude` — Anthropic's auto-updater target.
    /// 4. `/opt/homebrew/bin/claude` — Homebrew cask.
    /// 5. `/usr/local/bin/claude` — Intel Homebrew / manual install.
    /// 6. `claude` — bare name, resolved via PATH by the child process.
    static func resolvedPath() -> String {
        if let env = ProcessInfo.processInfo.environment["SONA_CLAUDE_BINARY"],
           !env.isEmpty {
            return env
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "\(home)/bin/claude-patched",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "claude"
    }
}
