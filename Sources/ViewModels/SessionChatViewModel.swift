import Foundation
import SwiftTerm
import AppKit
import SwiftUI

enum SessionState: Equatable {
    case uninitialized
    case running
    case stopped
    case restarting
}

/// Owns the embedded Claude Code session subprocess for the Dashboard's Session tab.
/// Reuses the WorkerCoordinator env-build helpers but does NOT register as a worker
/// (`SONA_WORKER=0`) — this session exists for human-driven conversation, not for
/// the dispatcher to assign events to.
@MainActor
final class SessionChatViewModel: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var state: SessionState = .uninitialized
    @Published var lastError: String?

    let terminalView: LocalProcessTerminalView
    private let sessionId: String
    private let workingDir: String

    /// Toggled by `restart()` so we can suppress the auto-respawn that would otherwise
    /// fire from `processTerminated` when the user explicitly asks to stop.
    private var pendingRestart: Bool = false

    override init() {
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 360))
        self.sessionId = UUID().uuidString.lowercased()

        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = "\(home)/.sonata/session"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.workingDir = dir

        super.init()
        terminalView.processDelegate = self

        // Cleanly SIGTERM the subprocess on app quit.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private nonisolated func handleAppWillTerminate(_ note: Notification) {
        // Best-effort SIGTERM. We're being torn down — no need to await main actor.
        let view = self.terminalView
        DispatchQueue.main.async {
            view.terminate()
        }
    }

    // MARK: - Lifecycle

    func spawn() {
        guard state != .running else { return }

        let env = SessionChatViewModel.buildEnvironment(sessionId: sessionId)

        var args: [String] = []
        args.append(contentsOf: ["--session-id", sessionId])
        args.append("--dangerously-skip-permissions")
        args.append(contentsOf: ["--dangerously-load-development-channels", "server:sonata-bridge"])
        args.append(contentsOf: ["--model", "claude-opus-4-7"])

        let terminal = terminalView.getTerminal()
        terminal.resetToInitialState()

        terminalView.startProcess(
            executable: SessionChatViewModel.claudeBinary,
            args: args,
            environment: env,
            currentDirectory: workingDir
        )

        state = .running
        lastError = nil

        // Auto-confirm the development-channels warning prompt — same trick the
        // worker spawner uses.
        for delay in [2.0, 4.0, 7.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if self.state == .running {
                    self.terminalView.send(txt: "\r")
                }
            }
        }
    }

    func stop() {
        pendingRestart = false
        terminalView.terminate()
        state = .stopped
    }

    func restart() {
        guard state == .running else {
            // Nothing live — just spawn fresh.
            spawn()
            return
        }
        pendingRestart = true
        state = .restarting
        terminalView.terminate()
        // Respawn happens in processTerminated.
    }

    /// Send raw text (with trailing carriage return) into the running subprocess's stdin.
    /// Caller is responsible for ensuring the session is running.
    func sendInput(_ text: String) {
        guard state == .running else { return }
        terminalView.send(txt: text)
    }

    /// Lazy-spawn convenience: if the subprocess hasn't been started yet, kick it off
    /// and queue the first user message to be typed once the prompt is ready.
    func sendFirstMessage(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if state == .uninitialized || state == .stopped {
            spawn()
            // Type the message after the Claude REPL has had a chance to come up.
            // The auto-confirm taps above handle the dev-channels prompt; queue our
            // payload after the last of those taps.
            let payload = trimmed
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
                guard let self else { return }
                if self.state == .running {
                    self.terminalView.send(txt: payload + "\r")
                }
            }
        } else if state == .running {
            terminalView.send(txt: trimmed + "\r")
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        let code = exitCode ?? -1
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.pendingRestart {
                self.pendingRestart = false
                self.state = .uninitialized
                // Tiny pause to let the OS reap the previous process.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.spawn()
                }
            } else {
                self.state = .stopped
                if code != 0 {
                    self.lastError = "Session exited with code \(code)."
                }
            }
        }
    }
}

// MARK: - Environment

extension SessionChatViewModel {
    static var claudeBinary: String {
        if let env = ProcessInfo.processInfo.environment["SONA_CLAUDE_BINARY"] {
            return env
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "claude"
    }

    /// Build the env for an embedded interactive Session subprocess. Mirrors
    /// `WorkerCoordinator.buildEnvironment` but flips `SONA_WORKER=0` so the
    /// sonata-bridge channel skips worker registration.
    static func buildEnvironment(sessionId: String) -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")

        let commonPaths = [
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
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? commonPaths.joined(separator: ":")
        let mergedPath = commonPaths.filter { !currentPath.contains($0) }.joined(separator: ":")
        env.append("PATH=\(mergedPath.isEmpty ? currentPath : "\(mergedPath):\(currentPath)")")

        env.append("HOME=\(home)")
        env.append("SONA_WORKER=0")
        env.append("SONATA_ROLE=session")
        env.append("SESSION_LABEL=dashboard-session")
        env.append("SONA_SESSION_ID=\(sessionId)")

        let passthrough = [
            "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY",
            "AGENTMAIL_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY",
            "CF_D1_EDIT_TOKEN", "CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_TOKEN",
            "EYEBROWSE_URL", "EYEBROWSE_TOKEN",
        ]
        let dotEnv = WorkerCoordinator.loadDotEnv(path: "\(home)/.sonata/.env")
        for key in passthrough {
            if let val = ProcessInfo.processInfo.environment[key] {
                env.append("\(key)=\(val)")
            } else if let val = dotEnv[key] {
                env.append("\(key)=\(val)")
            }
        }

        if let extra = ProcessInfo.processInfo.environment["SONA_EXTRA_ENV"] {
            for item in extra.components(separatedBy: ",") where !item.isEmpty {
                env.append(item)
            }
        }

        return env
    }
}
