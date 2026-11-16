import Foundation

/// The PATH and SHELL every process Sonata spawns should see.
///
/// Sonata is launched by launchd, so its own environment is the bare launchd one:
/// PATH=/usr/bin:/bin:/usr/sbin:/sbin and, usually, no SHELL at all. Children that
/// inherit that environment cannot find Homebrew tools, and anything that keys on
/// $SHELL sees nothing. Two failures that shipped from this (11/16):
///   - Worker claude processes had no SHELL=, so the zsh-trap hook (45c0eee),
///     which gated on $SHELL ending in zsh, never fired in any worker.
///   - Scheduler shell jobs ran without /opt/homebrew/bin, so `node` and `gh`
///     were "command not found" (ae192-breaker-observation, check-eyebrowse-*,
///     the April scout-* jobs).
///
/// Before this helper, each spawner carried its own copy of the PATH list (five
/// copies, three different lists). Every spawner now goes through here.
enum SpawnEnvironment {
    /// Shell used when Sonata's own environment has no SHELL.
    static let defaultShell = "/bin/zsh"

    /// Directories prepended to PATH when missing, most preferred first.
    static func commonPaths(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.nvm/versions/node/v25.8.1/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    /// `currentPath` with every common path it lacks prepended, in
    /// `commonPaths` order. Membership is by whole PATH component: the old
    /// copies used a substring test, so "/bin" counted as present whenever
    /// "/usr/bin" was, and "/opt/homebrew/bin" whenever "/opt/homebrew/bin/x" was.
    static func mergedPath(home: String, currentPath: String?) -> String {
        let common = commonPaths(home: home)
        guard let currentPath, !currentPath.isEmpty else {
            return common.joined(separator: ":")
        }
        let present = Set(currentPath.split(separator: ":").map(String.init))
        let missing = common.filter { !present.contains($0) }
        return missing.isEmpty ? currentPath : (missing + [currentPath]).joined(separator: ":")
    }

    /// Sonata's own SHELL when set and non-empty, else `/bin/zsh`.
    static func shell(from environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        return defaultShell
    }

    /// `PATH=` and `SHELL=` entries for a terminal-style `[String]` env.
    static func pathAndShellEntries(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        [
            "PATH=\(mergedPath(home: home, currentPath: environment["PATH"]))",
            "SHELL=\(shell(from: environment))",
        ]
    }

    /// Full environment for a `Process` (scheduler shell jobs): the base
    /// environment with PATH merged and SHELL filled in. Everything else in
    /// `base` passes through unchanged.
    static func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        let home = base["HOME"] ?? NSHomeDirectory()
        env["PATH"] = mergedPath(home: home, currentPath: base["PATH"])
        env["SHELL"] = shell(from: base)
        return env
    }
}
