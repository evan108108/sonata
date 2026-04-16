import Foundation
import SwiftTerm
import AppKit

/// Manages the supervisor Claude Code process, connected to a LocalProcessTerminalView.
/// Follows the same pattern as WorkerCoordinator but for the supervisor role.
final class SupervisorCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    weak var terminalView: LocalProcessTerminalView?
    private var autoRestart = true

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
        env.append("SONATA_ROLE=supervisor")
        env.append("WORKER_ID=supervisor")
        env.append("SESSION_LABEL=supervisor")

        if let extra = ProcessInfo.processInfo.environment["SONA_EXTRA_ENV"] {
            for item in extra.components(separatedBy: ",") where !item.isEmpty {
                env.append(item)
            }
        }

        let args: [String] = [
            "--dangerously-skip-permissions",
            "--dangerously-load-development-channels", "server:sonata-bridge",
            "--model", "claude-sonnet-4-6",
        ]

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
    }

    func stop() {
        autoRestart = false
        terminalView?.terminate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        print("[supervisor] Process exited with code: \(exitCode ?? -1)")
        guard autoRestart else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.startProcess()
        }
    }
}
