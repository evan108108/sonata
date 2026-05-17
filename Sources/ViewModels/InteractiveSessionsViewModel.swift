import Foundation
import SwiftTerm
import AppKit
import SwiftUI

enum InteractiveSessionState: Equatable {
    case starting
    case running
    case stopped(exitCode: Int32?)
    case spawnFailed(message: String)
}

/// One tab in the Interactive Sessions window — owns its own SwiftTerm terminal
/// view and Claude Code subprocess. Acts as the LocalProcessTerminalView delegate
/// so it can react to process termination on its own without a separate coordinator.
@MainActor
final class InteractiveSessionTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    @Published var name: String
    @Published var state: InteractiveSessionState = .starting

    let cwd: URL
    let terminalView: LocalProcessTerminalView
    private let sessionId: String

    init(id: UUID = UUID(), name: String, cwd: URL) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.sessionId = UUID().uuidString.lowercased()
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()
        terminalView.processDelegate = self
    }

    // MARK: - Lifecycle

    func spawn() {
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        // Per plan §6: opt-in in-proc MCP. SessionKey is a stable prefix
        // of the existing UUID so it satisfies MCPSessionKey.isValid
        // (1-128 [A-Za-z0-9_-]). Flag unset → behaviour unchanged.
        let mcpSessionKey = "session-" + sessionId.replacingOccurrences(of: "-", with: "").prefix(16)
        let inProcExtras = MCPSpawn.extraArgsForInProcMCP(
            sessionKey: String(mcpSessionKey),
            role: .interactive,
            slotLabel: "interactive"
        )
        let env = InteractiveSessionTab.buildEnvironment(sessionId: sessionId, omitLegacyRole: inProcExtras != nil)

        var args: [String] = []
        args.append(contentsOf: ["--session-id", sessionId])
        args.append("--dangerously-skip-permissions")
        args.append(contentsOf: ["--dangerously-load-development-channels", "server:sonata-bridge"])
        args.append(contentsOf: ["--model", "claude-opus-4-7"])
        if let extras = inProcExtras {
            args.append(contentsOf: extras)
        }

        let terminal = terminalView.getTerminal()
        terminal.resetToInitialState()

        let binary = InteractiveSessionTab.claudeBinary
        guard FileManager.default.isExecutableFile(atPath: binary) || binary == "claude" else {
            state = .spawnFailed(message: "Claude binary not found at \(binary)")
            return
        }

        terminalView.startProcess(
            executable: binary,
            args: args,
            environment: env,
            currentDirectory: cwd.path
        )
        state = .running

        // Auto-confirm the dev-channels warning prompt the same way workers do.
        for delay in [2.0, 4.0, 7.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if case .running = self.state {
                    self.terminalView.send(txt: "\r")
                }
            }
        }
    }

    func terminate() {
        terminalView.terminate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        let code = exitCode
        Task { @MainActor [weak self] in
            self?.state = .stopped(exitCode: code)
        }
    }
}

// MARK: - Environment

extension InteractiveSessionTab {
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

    /// Build env for an Interactive Sessions subprocess. Mirrors the WorkerCoordinator
    /// passthrough list but flips SONA_WORKER=0 and omits WORKER_ID / SESSION_LABEL —
    /// these are conversational sessions, not pool members.
    /// `omitLegacyRole` is set true by spawn() when the in-proc MCP path
    /// is active — the new server learns identity from the URL path so
    /// SONATA_ROLE=session is redundant and would confuse a side-by-side
    /// stdio bridge if both were live.
    static func buildEnvironment(sessionId: String, omitLegacyRole: Bool = false) -> [String] {
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
        if !omitLegacyRole {
            env.append("SONATA_ROLE=session")
        }
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

/// Owns the in-memory list of Interactive Sessions tabs across the whole app.
/// One instance per launch (singleton) so closing the window doesn't drop tabs.
@MainActor
final class InteractiveSessionsViewModel: ObservableObject {
    static let shared = InteractiveSessionsViewModel()

    @Published var tabs: [InteractiveSessionTab] = []
    @Published var activeTabId: UUID?

    /// Remembered when the window closes so reopening selects the same tab.
    private(set) var lastActiveTabId: UUID?

    private init() {
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

    // MARK: - Public API

    @discardableResult
    func addTab() -> InteractiveSessionTab {
        let index = nextSessionIndex()
        let name = "Session \(index)"
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let cwd = URL(fileURLWithPath: "\(home)/.sonata/session/session\(index)")

        let tab = InteractiveSessionTab(name: name, cwd: cwd)
        tabs.append(tab)
        selectTab(id: tab.id)

        DispatchQueue.main.async {
            tab.spawn()
        }
        return tab
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        tab.terminate()
        tabs.remove(at: idx)

        if activeTabId == id {
            // Prefer the tab to the right; if none, the previous one; else nil.
            let nextActive: UUID?
            if idx < tabs.count {
                nextActive = tabs[idx].id
            } else if idx - 1 >= 0, idx - 1 < tabs.count {
                nextActive = tabs[idx - 1].id
            } else {
                nextActive = nil
            }
            if let nextActive {
                selectTab(id: nextActive)
            } else {
                activeTabId = nil
            }
        }
    }

    func renameTab(id: UUID, name: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tab.name = trimmed
    }

    func selectTab(id: UUID) {
        activeTabId = id
        lastActiveTabId = id
    }

    func restartTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            tab.spawn()
        }
    }

    /// Called by the window controller when the window is reopened — restores
    /// the previously-selected tab if it still exists.
    func restoreLastActiveIfPossible() {
        if let last = lastActiveTabId, tabs.contains(where: { $0.id == last }) {
            activeTabId = last
        } else if activeTabId == nil, let first = tabs.first {
            activeTabId = first.id
        }
    }

    /// Step right (delta = +1) or left (delta = -1) through the tab list, wrapping.
    func cycleActiveTab(delta: Int) {
        guard !tabs.isEmpty else { return }
        let currentIdx = tabs.firstIndex(where: { $0.id == activeTabId }) ?? 0
        var newIdx = (currentIdx + delta) % tabs.count
        if newIdx < 0 { newIdx += tabs.count }
        selectTab(id: tabs[newIdx].id)
    }

    func closeActiveTab() {
        if let active = activeTabId {
            closeTab(id: active)
        }
    }

    // MARK: - Internals

    private func nextSessionIndex() -> Int {
        let usedIndices = tabs.compactMap { tab -> Int? in
            let prefix = "Session "
            guard tab.name.hasPrefix(prefix) else { return nil }
            return Int(tab.name.dropFirst(prefix.count))
        }
        return (usedIndices.max() ?? 0) + 1
    }

    @objc private nonisolated func handleAppWillTerminate(_ note: Notification) {
        // SIGTERM every subprocess on app quit. We can't await the main actor
        // safely from willTerminate; capture the views and signal them.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for tab in self.tabs {
                tab.terminate()
            }
        }
    }
}
