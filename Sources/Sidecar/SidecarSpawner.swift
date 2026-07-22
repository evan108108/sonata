import AppKit
import Foundation
import Logging
import SwiftTerm

// MARK: - Errors

/// Why a sidecar could not be started.
///
/// Every case is fatal to the spawn on purpose. Per the design spec's launch
/// behavior, a sidecar that cannot run must fail loudly: a session that came up
/// without instructions, or never came up at all while the registry believed it
/// had, is worse than a visible error at boot.
enum SidecarSpawnError: Error, CustomStringConvertible {
    case claudeBinaryMissing(path: String)
    case oauthCredentialsMissing(path: String)
    case resourceMissing(sidecar: String, resource: String)
    case provisioningFailed(sidecar: String, reason: String)

    var description: String {
        switch self {
        case .claudeBinaryMissing(let path):
            return "Claude binary not found or not executable at '\(path)' — set SONA_CLAUDE_BINARY or install Claude Code."
        case .oauthCredentialsMissing(let path):
            return "Claude Code OAuth credentials not found at '\(path)' — run `claude` once to sign in."
        case .resourceMissing(let sidecar, let resource):
            return "Sidecar '\(sidecar)' is missing bundled resource '\(resource)' — the app bundle is incomplete."
        case .provisioningFailed(let sidecar, let reason):
            return "Sidecar '\(sidecar)' working directory could not be provisioned: \(reason)"
        }
    }
}

// MARK: - Launch environment

/// Resolves the pieces of a sidecar launch that depend on the host machine.
///
/// Separated from the coordinator so the preconditions can be checked — and
/// failed on — before any window or process exists. `SidecarLifecycle.spawn`
/// treats a throw as fatal, and it is much easier to reason about a spawn that
/// refuses up front than one that half-creates a terminal and then dies.
enum SidecarLaunchEnvironment {

    /// Claude Code's OAuth credential file.
    ///
    /// This is the only credential check we make. Sonata authenticates to
    /// Claude exclusively through Claude Code's OAuth session — there is no
    /// `ANTHROPIC_API_KEY` in this environment and there is not meant to be, so
    /// probing for one would refuse to boot on a perfectly healthy machine.
    static var oauthCredentialsPath: String {
        "\(homeDirectory)/.claude/.credentials.json"
    }

    static var homeDirectory: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    /// Same resolution order as `SupervisorCoordinator`.
    static var claudeBinaryPath: String {
        ProcessInfo.processInfo.environment["SONA_CLAUDE_BINARY"]
            ?? "\(homeDirectory)/.local/bin/claude"
    }

    /// Throw unless this machine can actually run a sidecar.
    static func validatePreconditions() throws {
        let binary = claudeBinaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw SidecarSpawnError.claudeBinaryMissing(path: binary)
        }
        let credentials = oauthCredentialsPath
        guard FileManager.default.fileExists(atPath: credentials) else {
            throw SidecarSpawnError.oauthCredentialsMissing(path: credentials)
        }
    }
}

// MARK: - Provisioning

/// Lays down a sidecar's working directory from the app bundle.
///
/// A sidecar session is a plain Claude Code process whose instructions arrive
/// the way every Claude Code process gets them: a `CLAUDE.md` in its working
/// directory. The bundled `SKILL.md` is the source of truth, so it is copied
/// into place as `CLAUDE.md` on every spawn.
enum SidecarProvisioning {

    /// Basename the dispatcher's own prompt is written under.
    static let instructionsFilename = "CLAUDE.md"

    /// Working directory for `sidecar`, under the Sonata data directory
    /// alongside `worker/` and `supervisor/`.
    static func workingDirectory(for sidecar: Sidecar) -> String {
        URL(fileURLWithPath: SonataInstance.dataDirectory)
            .appendingPathComponent("sidecar-\(sidecar.name)")
            .path
    }

    /// Create the working directory and refresh its contents from the bundle.
    ///
    /// Files are overwritten on every spawn rather than preserved, matching
    /// `ensureBundledSkills`: these are app-owned instructions versioned with
    /// the binary, not user documents. Preserving a stale copy would let a
    /// sidecar keep running last release's prompt indefinitely.
    ///
    /// - Parameter extraResources: bundle basenames to copy verbatim beside the
    ///   instructions — for the memory sidecar, its per-request prompt template.
    static func provision(
        _ sidecar: Sidecar,
        bundleSubdirectory: String,
        extraResources: [String],
        logger: Logger
    ) throws {
        let fm = FileManager.default
        let workDir = workingDirectory(for: sidecar)

        do {
            try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        } catch {
            throw SidecarSpawnError.provisioningFailed(
                sidecar: sidecar.name, reason: error.localizedDescription)
        }

        // The dispatcher prompt: bundled SKILL.md becomes the session's CLAUDE.md.
        guard fm.fileExists(atPath: sidecar.skillPath) else {
            throw SidecarSpawnError.resourceMissing(sidecar: sidecar.name, resource: "SKILL.md")
        }
        let instructionsDest = "\(workDir)/\(instructionsFilename)"
        try replaceFile(at: instructionsDest, withContentsOf: sidecar.skillPath, sidecar: sidecar.name)

        for resource in extraResources {
            guard let source = Bundle.module.url(
                forResource: (resource as NSString).deletingPathExtension,
                withExtension: (resource as NSString).pathExtension,
                subdirectory: bundleSubdirectory
            ) else {
                throw SidecarSpawnError.resourceMissing(sidecar: sidecar.name, resource: resource)
            }
            try replaceFile(at: "\(workDir)/\(resource)", withContentsOf: source.path, sidecar: sidecar.name)
        }

        logger.info("sidecar '\(sidecar.name)' provisioned at \(workDir)")
    }

    private static func replaceFile(
        at destination: String,
        withContentsOf source: String,
        sidecar: String
    ) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination) {
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: source, toPath: destination)
        } catch {
            throw SidecarSpawnError.provisioningFailed(
                sidecar: sidecar, reason: "copying \(source) → \(destination): \(error.localizedDescription)")
        }
    }
}

// MARK: - Memory sidecar registration

/// Identity and registration for the memory sidecar — Sonata's first sidecar.
///
/// Kept beside the spawner rather than in the framework because the framework
/// is deliberately generic: it knows how to run *a* sidecar, not which ones
/// exist.
enum MemorySidecarRegistration {

    static let name = "memory"

    /// Routing key, `workers.workerId`, and MCP session key — deliberately one
    /// value.
    ///
    /// `SidecarLifecycle` reads both context usage and drain state with
    /// `SELECT ... FROM workers WHERE workerId = <handle.sessionKey>`. A
    /// spawner that registered the session under one identifier and routed to
    /// another would leave the monitor permanently blind: no usage readings, no
    /// rotation, and a drain that always reports idle.
    static let sessionKey = "sidecar-memory"

    /// Pool membership is decided by `sessionLabel GLOB 'sona-worker-*'`. This
    /// label sits outside that glob on purpose, so the generic dispatchers
    /// never hand the sidecar unrelated work. See the matching guards in
    /// `MCPEventPusher`, `SonataChannelServer`, and `TaskDispatcher`.
    static let sessionLabel = sessionKey

    static let eventTypes = ["memory_request"]

    /// Model backing the dispatcher loop. Matches the supervisor's rather than
    /// introducing a second model id: the dispatcher does almost no reasoning —
    /// it fills a template and spawns an agent — and the judge model that does
    /// the actual work is chosen per-request from the event payload.
    static let dispatcherModel = "claude-sonnet-4-6"

    /// Bundle subdirectory holding `SKILL.md` and `worker-prompt.md`.
    static let bundleSubdirectory = "sidecars/memory"

    /// Per-request prompt template, copied beside the instructions so the
    /// dispatcher can read it from its own working directory.
    static let workerPromptResource = "worker-prompt.md"

    /// Absolute path to the bundled `SKILL.md`, or nil when the app bundle is
    /// incomplete. Nil is surfaced as a refusal to register rather than a
    /// sidecar that fails later at spawn time.
    static func bundledSkillPath() -> String? {
        Bundle.module.url(
            forResource: "SKILL", withExtension: "md", subdirectory: bundleSubdirectory
        )?.path
    }

    /// Build the registration, folding the user's stored config over the
    /// defaults so a tuned tier or cap survives relaunch.
    ///
    /// Kind is `.inProcess`: the handler lives in `MemorySidecarHandler` and
    /// runs `mem_recall` server-side in Swift. `skillPath` is now vestigial
    /// (empty string) — kept in the initializer signature so the Claude Code
    /// spawn path stays the framework's default without touching every call
    /// site. `skillFileExists` guards in `SidecarLifecycle.spawn` only run
    /// for `.claudeCode`, so an empty path is safe here.
    static func sidecar(skillPath: String, config: SidecarUserConfig) -> Sidecar {
        Sidecar(
            name: name,
            skillPath: skillPath,
            eventTypes: eventTypes,
            budgetTier: config.tier,
            subscriptionCapPct: config.subscriptionCapPct,
            triggers: config.triggers,
            rotationThreshold: config.rotationThreshold,
            kind: .inProcess
        )
    }
}

// MARK: - Process coordinator

/// Owns one sidecar's Claude Code process, mirroring `SupervisorCoordinator`.
///
/// The differences from the supervisor are deliberate:
/// - identity is minted for `role: .worker`, because that is the role the
///   framework's monitor and drain check read against. Registering the
///   `workers` row itself is done here (`registerWorkerRow`) rather than
///   inherited: that used to fall out of sonata-bridge.ts registering on boot,
///   and that bridge is no longer deployed;
/// - a FRESH `--session-id` per spawn, not a stable one — a rotation still
///   comes up as a new conversation, which is the entire point of rotating,
///   while still naming a transcript the context monitor can attribute;
/// - `stop()` disables auto-restart before terminating, so a rotation's
///   terminate is not immediately undone by the respawn timer.
final class SidecarCoordinator: NSObject, LocalProcessTerminalViewDelegate {

    /// Delay before an unexpected exit is retried, seconds.
    private static let restartDelay: TimeInterval = 5.0
    /// Delay between window creation and process start, giving the terminal
    /// view a layout pass so the PTY comes up with a sane size.
    static let startupDelay: TimeInterval = 1.0
    /// Delay before registering the `workers` row, letting the session get its
    /// process up first. Same 5s the pool workers use.
    static let registrationDelay: TimeInterval = 5.0

    weak var terminalView: LocalProcessTerminalView?

    let sidecarName: String
    let sessionKey: String
    let sessionLabel: String
    let model: String
    let workingDirectory: String

    /// Cleared by `stop()` so an intentional teardown does not respawn.
    private var autoRestart = true
    private let logger: Logger

    init(
        sidecarName: String,
        sessionKey: String,
        sessionLabel: String,
        model: String,
        workingDirectory: String,
        terminalView: LocalProcessTerminalView,
        logger: Logger
    ) {
        self.sidecarName = sidecarName
        self.sessionKey = sessionKey
        self.sessionLabel = sessionLabel
        self.model = model
        self.workingDirectory = workingDirectory
        self.terminalView = terminalView
        self.logger = logger
        super.init()
    }

    func startProcess() {
        guard let view = terminalView else { return }

        let home = SidecarLaunchEnvironment.homeDirectory
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")

        let commonPaths = [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let currentPath = ProcessInfo.processInfo.environment["PATH"]
            ?? commonPaths.joined(separator: ":")
        let mergedPath = commonPaths.filter { !currentPath.contains($0) }.joined(separator: ":")
        env.append("PATH=\(mergedPath.isEmpty ? currentPath : "\(mergedPath):\(currentPath)")")
        env.append("HOME=\(home)")
        env.append("SONA_WORKER=1")

        // Identity. `role: .worker` is the role the monitor and drain check
        // read against; the sidecar is kept out of the worker *pool* by its
        // sessionLabel, not by its role. The row itself is created by
        // `registerWorkerRow` below.
        let inProcExtras = MCPSpawn.extraArgsForInProcMCP(
            sessionKey: sessionKey,
            role: .worker,
            slotLabel: sessionLabel
        )
        if inProcExtras == nil {
            env.append("SONATA_ROLE=worker")
            env.append("WORKER_ID=\(sessionKey)")
            env.append("SESSION_LABEL=\(sessionLabel)")
        }

        // Fresh conversation id per spawn. Rotation's point is a fresh CONTEXT,
        // not the absence of an identifier — and without one there is no way to
        // tell which transcript on disk belongs to this session, which is what
        // the context monitor measures occupancy from. Minted per start so a
        // rotated sidecar never resumes its predecessor's conversation.
        let claudeSessionId = UUID().uuidString.lowercased()

        var args: [String] = [
            "--session-id", claudeSessionId,
            "--dangerously-skip-permissions",
            "--dangerously-load-development-channels", "server:sonata-bridge",
            "--model", model,
        ]
        if let extras = inProcExtras {
            args.append(contentsOf: extras)
        }

        let terminal = view.getTerminal()
        terminal.resetToInitialState()

        view.startProcess(
            executable: SidecarLaunchEnvironment.claudeBinaryPath,
            args: args,
            environment: env,
            currentDirectory: workingDirectory
        )

        logger.info("sidecar '\(sidecarName)' process started as \(sessionKey) in \(workingDirectory)")

        registerWorkerRow(claudeSessionId: claudeSessionId)

        // Auto-confirm the development-channels warning prompt, same cadence
        // the supervisor uses.
        for delay in [2.0, 4.0, 7.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.terminalView?.send(txt: "\r")
            }
        }
    }

    /// Create this sidecar's `workers` row, carrying the conversation id its
    /// transcript is named after.
    ///
    /// The row is not optional bookkeeping — three things the framework does
    /// read it by `workerId == sessionKey`: the context monitor's occupancy
    /// query, `SidecarLifecycle.drain`'s busy check, and the sweeper's
    /// heartbeat. Until Phase D this happened for free, because sonata-bridge.ts
    /// registered on boot. That bridge is no longer deployed, so nothing
    /// registered the sidecar at all and every one of those reads found no row.
    ///
    /// Mirrors how `WorkersView` registers pool workers, including the delay:
    /// registration is a courtesy the app performs on the session's behalf once
    /// its process is up. `sessionLabel` is the sidecar's own key, never
    /// `sona-worker-N`, so this row stays outside the dispatch pool
    /// (`poolSlotSQLPredicate` globs `sona-worker-*`).
    private func registerWorkerRow(claudeSessionId: String) {
        let port = Int(ProcessInfo.processInfo.environment["SONATA_PORT"] ?? "") ?? 3211
        guard let url = URL(string: "http://localhost:\(port)/api/worker/register") else { return }
        let workerId = sessionKey
        let label = sessionLabel
        let name = sidecarName
        let log = logger

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.registrationDelay) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "workerId": workerId,
                "sessionLabel": label,
                "sessionId": claudeSessionId,
                // Sidecars are routed to by event_type through SidecarRegistry,
                // not by capability matching, so this stays empty rather than
                // advertising work the sidecar will not do.
                "capabilities": [String](),
            ])
            URLSession.shared.dataTask(with: req) { _, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if let error {
                    log.warning("sidecar '\(name)' worker registration failed: \(error)")
                } else if !(200..<300).contains(status) {
                    log.warning("sidecar '\(name)' worker registration returned HTTP \(status)")
                } else {
                    log.info("sidecar '\(name)' registered as \(workerId) (session \(claudeSessionId))")
                }
            }.resume()
        }
    }

    /// Stand the process down for good. Idempotent — `SidecarLifecycle` may
    /// terminate a session that already exited on its own after posting
    /// `rotate_me`.
    func stop() {
        autoRestart = false
        terminalView?.terminate()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        logger.info("sidecar '\(sidecarName)' process exited with code \(exitCode ?? -1)")
        guard autoRestart else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay) { [weak self] in
            guard let self, self.autoRestart else { return }
            self.startProcess()
        }
    }
}

// MARK: - Window controller

/// Holds each sidecar's hidden window and coordinator.
///
/// Sidecars are created hidden, exactly like the supervisor: the process must
/// run whether or not anyone ever opens the window. `show(name:)` is the hook
/// the Window menu calls — the menu itself is owned elsewhere, so this type
/// exposes the entry point without reaching into menu code.
@MainActor
final class SidecarWindowController: NSObject, NSWindowDelegate {
    static let shared = SidecarWindowController()

    private static let windowSize = NSRect(x: 0, y: 0, width: 1000, height: 700)

    private var windows: [String: NSWindow] = [:]
    private var coordinators: [String: SidecarCoordinator] = [:]

    private override init() { super.init() }

    /// Create the window and start the process for `sidecar` if it isn't
    /// already running. Returns the live coordinator either way.
    @discardableResult
    func ensureStarted(
        sidecar: Sidecar,
        sessionKey: String,
        sessionLabel: String,
        model: String,
        workingDirectory: String,
        logger: Logger
    ) -> SidecarCoordinator {
        if let existing = coordinators[sidecar.name] { return existing }

        let termView = DropEnabledTerminalView(frame: Self.windowSize)
        termView.applyWarmChrome()
        termView.enableWarmTerminalColors()

        let coordinator = SidecarCoordinator(
            sidecarName: sidecar.name,
            sessionKey: sessionKey,
            sessionLabel: sessionLabel,
            model: model,
            workingDirectory: workingDirectory,
            terminalView: termView,
            logger: logger
        )
        termView.processDelegate = coordinator
        coordinators[sidecar.name] = coordinator

        let window = NSWindow(
            contentRect: Self.windowSize,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidecar — \(sidecar.name)"
        window.contentView = termView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[sidecar.name] = window

        // Start after a layout pass, matching the supervisor.
        DispatchQueue.main.asyncAfter(deadline: .now() + SidecarCoordinator.startupDelay) {
            coordinator.startProcess()
        }
        return coordinator
    }

    /// Bring a sidecar's window to the front, starting nothing that isn't
    /// already running. Returns false when the sidecar has no live session.
    @discardableResult
    func show(name: String) -> Bool {
        guard let window = windows[name] else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Stop the process and drop the window. Called by the lifecycle's
    /// terminate handle during rotation.
    func terminate(name: String) {
        coordinators[name]?.stop()
        coordinators[name] = nil
        if let window = windows.removeValue(forKey: name) {
            window.delegate = nil
            window.orderOut(nil)
        }
    }

    /// Names of sidecars with a live coordinator — used by the Window menu to
    /// decide what to list.
    func runningNames() -> [String] { Array(coordinators.keys) }

    // MARK: NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        DispatchQueue.main.async { sender.orderOut(nil) }
        return false
    }
}

// MARK: - Runtime

/// Process-wide handle on the live sidecar subsystem.
///
/// Boot constructs the lifecycle and the spend tracker; code that runs later
/// and elsewhere — the `rotate_me` handler, the settings panel — needs to reach
/// them without threading a reference through every call site. Same
/// lock-guarded `final class` + `static let shared` shape as `SidecarRegistry`
/// and `SidecarSpendRegistry`, and for the same reason: installation is
/// synchronous and an actor would push an `await` into boot.
final class SidecarRuntime: @unchecked Sendable {
    static let shared = SidecarRuntime()

    private var storedLifecycle: SidecarLifecycle?
    private var storedTracker: SidecarSpendTracker?
    private let lock = NSLock()

    private init() {}

    /// Publish the live subsystem. Called once at boot.
    func install(lifecycle: SidecarLifecycle, tracker: SidecarSpendTracker) {
        lock.lock()
        defer { lock.unlock() }
        storedLifecycle = lifecycle
        storedTracker = tracker
    }

    /// The running lifecycle, or nil when sidecars never booted (no OAuth
    /// credentials, no claude binary, or every sidecar registered `.off`).
    var lifecycle: SidecarLifecycle? {
        lock.lock()
        defer { lock.unlock() }
        return storedLifecycle
    }

    var tracker: SidecarSpendTracker? {
        lock.lock()
        defer { lock.unlock() }
        return storedTracker
    }

    /// Tear down for tests.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        storedLifecycle = nil
        storedTracker = nil
    }
}

// MARK: - Spawner

/// Builds the `SidecarLifecycle.Spawner` the app runs in production.
///
/// The closure validates preconditions, lays down the working directory, and
/// brings up a hidden terminal window — throwing rather than returning a handle
/// if any step fails, so `SidecarLifecycle` never publishes a session key for a
/// sidecar that isn't actually running.
enum SidecarSpawnerFactory {

    static func make(logger: Logger) -> SidecarLifecycle.Spawner {
        return { @Sendable sidecar in
            try SidecarLaunchEnvironment.validatePreconditions()

            // Only the memory sidecar exists today. Resolving its extras here
            // rather than in the framework keeps `Sidecar` free of per-sidecar
            // knowledge; a second sidecar adds a case, not a protocol.
            let bundleSubdirectory: String
            let extraResources: [String]
            let model: String
            let sessionKey: String
            let sessionLabel: String
            if sidecar.name == MemorySidecarRegistration.name {
                bundleSubdirectory = MemorySidecarRegistration.bundleSubdirectory
                extraResources = [MemorySidecarRegistration.workerPromptResource]
                model = MemorySidecarRegistration.dispatcherModel
                sessionKey = MemorySidecarRegistration.sessionKey
                sessionLabel = MemorySidecarRegistration.sessionLabel
            } else {
                bundleSubdirectory = "sidecars/\(sidecar.name)"
                extraResources = []
                model = MemorySidecarRegistration.dispatcherModel
                sessionKey = "sidecar-\(sidecar.name)"
                sessionLabel = sessionKey
            }

            try SidecarProvisioning.provision(
                sidecar,
                bundleSubdirectory: bundleSubdirectory,
                extraResources: extraResources,
                logger: logger
            )
            let workingDirectory = SidecarProvisioning.workingDirectory(for: sidecar)

            await MainActor.run {
                _ = SidecarWindowController.shared.ensureStarted(
                    sidecar: sidecar,
                    sessionKey: sessionKey,
                    sessionLabel: sessionLabel,
                    model: model,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
            }

            let terminatedName = sidecar.name
            return SidecarSessionHandle(sessionKey: sessionKey) {
                await MainActor.run {
                    SidecarWindowController.shared.terminate(name: terminatedName)
                }
            }
        }
    }
}
