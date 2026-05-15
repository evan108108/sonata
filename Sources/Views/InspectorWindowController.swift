import Foundation
import SwiftTerm
import AppKit

/// Manages an inspector Claude Code session — a resumed session for inspecting
/// a past worker task. No registration, no event claiming, MCP tools available.
final class InspectorWindowController: NSObject, LocalProcessTerminalViewDelegate {
    let sessionId: String
    let taskTitle: String
    private var window: NSWindow?
    private var terminalView: LocalProcessTerminalView?

    init(sessionId: String, taskTitle: String = "Inspector") {
        self.sessionId = sessionId
        self.taskTitle = taskTitle
        super.init()
    }

    var isOpen: Bool { window != nil }

    func open() {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        tv.applyWarmChrome()
        tv.processDelegate = self
        self.terminalView = tv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Inspector: \(taskTitle) (\(sessionId.prefix(8))…)"
        win.contentView = tv
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.delegate = self
        self.window = win

        startProcess(in: tv)
    }

    private func startProcess(in view: LocalProcessTerminalView) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let claudeBinary = WorkerManager.claudeBinary

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let commonPaths = [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.nvm/versions/node/v25.8.1/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? commonPaths.joined(separator: ":")
        let mergedPath = commonPaths.filter { !currentPath.contains($0) }.joined(separator: ":")
        env.append("PATH=\(mergedPath.isEmpty ? currentPath : "\(mergedPath):\(currentPath)")")
        env.append("HOME=\(home)")
        env.append("SONA_WORKER=1")
        env.append("SONATA_ROLE=inspector")

        // Pass through auth keys
        let dotEnv = WorkerCoordinator.loadDotEnv(path: "\(home)/.sonata/.env")
        let passthrough = [
            "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY",
            "AGENTMAIL_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY",
        ]
        for key in passthrough {
            if let val = ProcessInfo.processInfo.environment[key] {
                env.append("\(key)=\(val)")
            } else if let val = dotEnv[key] {
                env.append("\(key)=\(val)")
            }
        }

        let args: [String] = [
            "--resume", sessionId,
            "--dangerously-skip-permissions",
            "--dangerously-load-development-channels", "server:sonata-bridge",
        ]

        let terminal = view.getTerminal()
        terminal.resetToInitialState()

        view.startProcess(
            executable: claudeBinary,
            args: args,
            environment: env,
            currentDirectory: WorkerManager.workingDirectory
        )

        // Auto-confirm development channels prompt
        for delay in [2.0, 4.0, 7.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                view?.send(txt: "\r")
            }
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        print("[inspector] Session \(sessionId.prefix(8)) exited with code: \(exitCode ?? -1)")
    }
}

extension InspectorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        terminalView?.terminate()
        window = nil
        terminalView = nil
    }
}


// MARK: - Inspector Window Store

/// Retains InspectorWindowController instances so they don't get deallocated.
class InspectorWindowStore {
    static let shared = InspectorWindowStore()
    private var controllers: [InspectorWindowController] = []

    func add(_ controller: InspectorWindowController) {
        controllers.removeAll { !$0.isOpen }
        controllers.append(controller)
    }

    private init() {}
}
