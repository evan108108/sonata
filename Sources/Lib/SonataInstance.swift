import Foundation

/// Identity and isolation for a single running Sonata process.
///
/// Sonata owns a lot of machine-wide state: the SQLite database, the plugin
/// daemons, MeiliSearch on a fixed port, and — most dangerously — the MCP
/// endpoint recorded in `~/.claude.json` and `~/.claude/mcp.json`, which is how
/// every Claude Code session on the machine finds Sonata at all.
///
/// A second Sonata process launched against that same state does not merely
/// coexist badly; it silently takes over. On 2026-07-13 a debug binary was
/// side-launched on a spare port to test a change. Within milliseconds it had
/// rewritten the global MCP config to point at its own port, restarted the
/// plugin daemons under itself, and opened the live database. When it was
/// killed the whole worker fleet lost its channel.
///
/// Two invariants prevent a repeat:
///
///   1. **A data directory has one owner.** Enforced by an exclusive `flock` on
///      `<dataDir>/sonata.lock`, taken before the database is opened. A second
///      process on the same data dir yields; the running one is never disturbed.
///   2. **Only the primary instance writes global user config.** A secondary
///      instance (non-default data dir or non-default port) keeps its hands off
///      `~/.claude.json`, `~/.zshrc`, `~/.claude/skills`, and the shared ports.
enum SonataInstance {

    /// The port `/Applications/Sonata.app` listens on. The fleet's MCP config
    /// points here, so an instance on any other port is by definition not the
    /// one the fleet is talking to.
    static let defaultPort = 3211

    /// The port this process serves on. `$SONATA_PORT` overrides.
    static let port: Int = resolvePort(env: ProcessInfo.processInfo.environment)

    /// Where Sonata keeps its data. `$SONATA_DATA_DIR` overrides; otherwise
    /// `~/.sonata`.
    ///
    /// This override is the **only** supported way to sandbox an instance.
    /// Setting `$HOME` does not work and never did: `homeDirectoryForCurrentUser`
    /// resolves through `getpwuid(getuid())`, which reads the passwd database
    /// and ignores the environment entirely. A dev binary launched with
    /// `HOME=/tmp/scratch` opens the real `~/.sonata/sonata.db`.
    static let dataDirectory: String = resolveDataDirectory(
        env: ProcessInfo.processInfo.environment, home: homePath)

    /// `~/.sonata` — the data dir the installed app uses.
    static let defaultDataDirectory: String = "\(homePath)/.sonata"

    private static var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: - Resolution (pure, so it can be tested without touching the env)

    static func resolvePort(env: [String: String]) -> Int {
        Int(env["SONATA_PORT"] ?? "") ?? defaultPort
    }

    static func resolveDataDirectory(env: [String: String], home: String) -> String {
        if let override = env["SONATA_DATA_DIR"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return "\(home)/.sonata"
    }

    /// Whether an instance with this (dataDirectory, port) owns the machine-wide
    /// singletons. Split out from `isPrimary` so the rule itself is testable.
    static func isPrimary(dataDirectory: String, port: Int, home: String) -> Bool {
        dataDirectory == "\(home)/.sonata" && port == defaultPort
    }

    /// True when this process is the machine's primary Sonata: default data dir
    /// *and* default port. Only the primary may touch state shared with the rest
    /// of the machine — the global MCP config, the `sona` shell launcher,
    /// `~/.claude/skills`, MeiliSearch's fixed port, and the plugin daemons.
    ///
    /// The port matters as much as the data dir. An instance on the real data
    /// dir but a different port would otherwise republish the fleet's MCP
    /// endpoint as its own — the exact failure of 2026-07-13.
    static var isPrimary: Bool {
        isPrimary(dataDirectory: dataDirectory, port: port, home: homePath)
    }

    /// Human-readable role, for the boot log.
    static var roleDescription: String {
        isPrimary
            ? "primary (data dir \(dataDirectory), port \(port))"
            : "secondary (data dir \(dataDirectory), port \(port))"
    }

    // MARK: - Single-instance lock

    /// Held for the life of the process. Never closed: the kernel releases the
    /// flock when the process exits, which is what makes a crashed instance
    /// leave no stale lock behind.
    ///
    /// That guarantee holds *only* because the descriptor is opened
    /// `O_CLOEXEC`. flock is per open-file-description, not per process, so a
    /// child that inherits this descriptor across fork+exec keeps the lock
    /// alive after the parent dies. Sonata forks workers (forkpty) and plugins
    /// constantly, so without the flag a crash leaves the data dir locked by
    /// orphans and every relaunch attempt hits the singleton guard and
    /// exit(0)s — observed on 2026-07-19 defeating the LaunchAgent's KeepAlive.
    private nonisolated(unsafe) static var lockDescriptor: Int32 = -1

    /// Test hook: is the held lock descriptor marked close-on-exec?
    /// `nil` when no lock is currently held.
    static var lockDescriptorIsCloseOnExec: Bool? {
        guard lockDescriptor >= 0 else { return nil }
        let flags = fcntl(lockDescriptor, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }

    /// Test hook: release the held lock so a test can simulate process exit
    /// without tearing down the test runner.
    static func releaseLockForTesting() {
        guard lockDescriptor >= 0 else { return }
        close(lockDescriptor)
        lockDescriptor = -1
    }

    /// Take the exclusive lock on this data directory.
    ///
    /// Returns `false` if another live process already holds it — i.e. a Sonata
    /// is already running against this data dir and this process must yield.
    ///
    /// The lock file lives *inside* the data dir, so isolation falls out for
    /// free: an instance with `SONATA_DATA_DIR` set locks a different file and
    /// starts happily alongside the installed app.
    static func acquireLock() -> Bool {
        acquireLock(at: dataDirectory)
    }

    /// Testable form. Returns `false` when the directory's lock is already held
    /// by a live open file description — including one in this same process,
    /// since flock is per-description, not per-process.
    @discardableResult
    static func acquireLock(at directory: String) -> Bool {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        let path = "\(directory)/sonata.lock"
        // O_CLOEXEC is load-bearing, not hygiene — see `lockDescriptor`.
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)

        // Can't open the lock file at all (read-only volume, exotic perms).
        // Refusing to boot over an unlockable path would be worse than the race
        // it protects against, so allow the launch.
        guard descriptor >= 0 else { return true }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }

        lockDescriptor = descriptor
        return true
    }
}
