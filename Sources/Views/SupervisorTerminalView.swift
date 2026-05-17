import Foundation
import SwiftTerm
import AppKit

/// Manages the supervisor Claude Code process, connected to a LocalProcessTerminalView.
/// Follows the same pattern as WorkerCoordinator but for the supervisor role.
final class SupervisorCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    weak var terminalView: LocalProcessTerminalView?
    private var autoRestart = true

    // Bridge-child watchdog: if the supervisor claude process is alive but its
    // `bun sonata-bridge.ts` MCP child has died, no heartbeats reach the
    // backend → HealthMonitor's 60s freshness guard stops queuing checks →
    // silent deadlock. Detect a missing bridge child across two consecutive
    // samples and SIGKILL the supervisor; processTerminated auto-respawns it.
    private var watchdogTimer: Timer?
    private var watchdogMissingSamples: Int = 0
    private static let watchdogStartDelay: TimeInterval = 90  // give MCP children time to load
    private static let watchdogInterval: TimeInterval = 60
    private static let watchdogMissingThreshold: Int = 2

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init()
    }

    func startProcess() {
        guard let view = terminalView else { return }

        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let claudeBinary = ProcessInfo.processInfo.environment["SONA_CLAUDE_BINARY"]
            ?? "\(home)/.local/bin/claude"

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let commonPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? commonPaths.joined(separator: ":")
        let mergedPath = commonPaths.filter { !currentPath.contains($0) }.joined(separator: ":")
        env.append("PATH=\(mergedPath.isEmpty ? currentPath : "\(mergedPath):\(currentPath)")")
        env.append("HOME=\(home)")
        env.append("SONA_WORKER=1")

        // Per plan §6: opt into in-proc MCP HTTP+SSE via SONATA_MCP_INPROC=1.
        // If unset (or registry not yet published, or credential write
        // fails), fall back to today's env-var bridge — supervisor remains
        // byte-for-byte identical to pre-§6.
        let inProcExtras = MCPSpawn.extraArgsForInProcMCP(sessionKey: "supervisor", role: .supervisor)
        if inProcExtras == nil {
            env.append("SONATA_ROLE=supervisor")
            env.append("WORKER_ID=supervisor")
            env.append("SESSION_LABEL=supervisor")
        }

        if let extra = ProcessInfo.processInfo.environment["SONA_EXTRA_ENV"] {
            for item in extra.components(separatedBy: ",") where !item.isEmpty {
                env.append(item)
            }
        }

        var args: [String] = [
            "--dangerously-skip-permissions",
            "--dangerously-load-development-channels", "server:sonata-bridge",
            "--model", "claude-sonnet-4-6",
        ]
        if let extras = inProcExtras {
            args.append(contentsOf: extras)
        }

        let terminal = view.getTerminal()
        terminal.resetToInitialState()

        view.startProcess(
            executable: claudeBinary,
            args: args,
            environment: env,
            currentDirectory: "\(home)/.sonata/supervisor"
        )

        // Auto-confirm the development channels warning prompt
        for delay in [2.0, 4.0, 7.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.terminalView?.send(txt: "\r")
            }
        }

        // Watchdog only makes sense in the legacy stdio-bridge path. In
        // the in-proc HTTP path there's no bun child process to watch;
        // SSE writer drop is the presence signal. (Plan §6, removal
        // queued for Phase D step 1.)
        if !MCPSpawn.inProcEnabled {
            startBridgeWatchdog()
        }
    }

    func stop() {
        autoRestart = false
        stopBridgeWatchdog()
        terminalView?.terminate()
    }

    // MARK: - Bridge-child watchdog

    private func startBridgeWatchdog() {
        stopBridgeWatchdog()
        watchdogMissingSamples = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogStartDelay) { [weak self] in
            guard let self, self.autoRestart else { return }
            self.watchdogTimer = Timer.scheduledTimer(
                withTimeInterval: Self.watchdogInterval,
                repeats: true
            ) { [weak self] _ in
                self?.checkBridgeChild()
            }
        }
    }

    private func stopBridgeWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        watchdogMissingSamples = 0
    }

    private func checkBridgeChild() {
        guard autoRestart else { return }
        guard let pid = terminalView?.process?.shellPid, pid > 0 else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hasBridge = SupervisorCoordinator.hasBridgeChild(supervisorPid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let currentPid = self.terminalView?.process?.shellPid, currentPid == pid else {
                    // Supervisor was replaced underneath us — reset and let the
                    // next tick observe the new process.
                    self.watchdogMissingSamples = 0
                    return
                }
                if hasBridge {
                    if self.watchdogMissingSamples > 0 {
                        print("[supervisor-watchdog] bridge child observed; resetting counter")
                    }
                    self.watchdogMissingSamples = 0
                    return
                }
                self.watchdogMissingSamples += 1
                print("[supervisor-watchdog] bridge child missing (sample \(self.watchdogMissingSamples)/\(Self.watchdogMissingThreshold)) pid=\(pid)")
                if self.watchdogMissingSamples >= Self.watchdogMissingThreshold {
                    print("[supervisor-watchdog] SIGKILL supervisor pid=\(pid) — bridge child gone; respawn will follow")
                    self.stopBridgeWatchdog()
                    kill(pid_t(pid), SIGKILL)
                }
            }
        }
    }

    /// Run `pgrep -P <pid>` and look for a `bun ... sonata-bridge.ts` child.
    /// Returns true only when at least one matching child is found.
    private static func hasBridgeChild(supervisorPid: Int32) -> Bool {
        let childPids = runPipe(
            path: "/usr/bin/pgrep",
            args: ["-P", String(supervisorPid)]
        )
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        guard !childPids.isEmpty else { return false }

        let cmdLines = runPipe(
            path: "/bin/ps",
            args: ["-o", "command=", "-p"] + childPids.map { String($0) }
        )
        for line in cmdLines.split(whereSeparator: \.isNewline) {
            if line.contains("sonata-bridge.ts") && line.contains("bun") {
                return true
            }
        }
        return false
    }

    private static func runPipe(path: String, args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return ""
        }
        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        print("[supervisor] Process exited with code: \(exitCode ?? -1)")
        stopBridgeWatchdog()
        guard autoRestart else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.startProcess()
        }
    }
}
