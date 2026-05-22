import Foundation
import GRDB
import SwiftTerm
import AppKit
import SwiftUI
import WebKit

enum InteractiveSessionState: Equatable {
    case starting
    case running
    case stopped(exitCode: Int32?)
    case spawnFailed(message: String)
}

/// What a session tab runs. `sona` is the full Claude Code subprocess (the
/// default and original behavior); `terminal` is a plain interactive shell.
/// Modeled as a first-class enum (not a bool) so more session types can be
/// added later without reworking call sites or the persistence schema.
enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case sona
    case terminal
    case webview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sona: return "Sona"
        case .terminal: return "Terminal"
        case .webview: return "Web"
        }
    }

    /// SF Symbol shown in the sessions sidebar so the kind is identifiable at
    /// a glance (replaces the old plain status dot).
    var iconName: String {
        switch self {
        case .sona: return "flame.fill"
        case .terminal: return "terminal.fill"
        case .webview: return "globe"
        }
    }

    /// True for kinds backed by a subprocess + terminal view (Sona, Terminal).
    /// Web sessions are backed by a WKWebView instead.
    var isTerminalBacked: Bool { self != .webview }
}

/// One tab in the Interactive Sessions window. Content-type-aware: a
/// terminal-backed session (Sona / Terminal) owns a SwiftTerm view + subprocess
/// and acts as its `LocalProcessTerminalViewDelegate`; a Web session owns a
/// WKWebView and acts as its `WKNavigationDelegate`. `contentView` exposes
/// whichever to the SwiftUI container.
@MainActor
final class InteractiveSessionTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate, WKNavigationDelegate {
    let id: UUID
    @Published var name: String
    @Published var state: InteractiveSessionState = .starting
    /// One-shot trigger so the rail-side `SessionsView` row can ask its
    /// inline TextField to enter rename mode from the right-click context
    /// menu. Set to true, the row observes the change and flips itself
    /// back to false. Not a true command-pattern; just a published bool
    /// that's enough for v0 of the in-rail Sessions UI.
    @Published var beginRenameRequested: Bool = false

    let cwd: URL
    let sessionId: String

    /// What this tab runs (Sona = Claude Code, terminal = plain shell,
    /// webview = a WKWebView pointed at `url`).
    let kind: SessionKind

    /// Target URL for `.webview` sessions; nil for terminal-backed kinds.
    let url: URL?

    // Exactly one of these is non-nil, selected by `kind`. `contentView`
    // exposes whichever to the SwiftUI container.
    let terminal: LocalProcessTerminalView?
    let webView: WKWebView?

    /// The NSView to mount for this session — terminal or webview.
    var contentView: NSView {
        if let terminal { return terminal }
        if let webView { return webView }
        fatalError("InteractiveSessionTab has no content view")
    }

    /// Sidebar subtitle: the host for web sessions, the working directory's
    /// last path component for terminal-backed kinds.
    var subtitle: String {
        switch kind {
        case .webview: return url?.host ?? url?.absoluteString ?? "—"
        default: return cwd.lastPathComponent
        }
    }

    /// Stable MCP-side identifier for this tab — what shows up as the
    /// sessionKey in MCPSessionRegistry, used by the dashboard's
    /// Connected/Unconnected sections to find the human-readable name
    /// ("Session 1" / "My Session") attached to the tab.
    var mcpSessionKey: String {
        "session-" + sessionId.replacingOccurrences(of: "-", with: "").prefix(16)
    }

    /// True when the tab was restored from the v14 `interactiveSessions`
    /// table and should re-attach via `--resume <sessionId>` instead of
    /// minting a fresh session. Flipped to false after a Restart so the
    /// fallback path (--session-id) gets tried if the first --resume
    /// attempt failed.
    private(set) var resume: Bool

    /// Wall-clock time of the most recent spawn. Used to detect "--resume
    /// failed almost immediately" (claude exits ~instantly with code 1
    /// when ~/.claude/projects/<...>/<sessionId>.jsonl is missing — the
    /// common case for sessions that never had any conversation). On a
    /// quick exit in resume mode, we silently fall back to --session-id
    /// instead of showing the user a "Session ended" error screen for a
    /// failure that wasn't theirs.
    private var lastSpawnAt: Date = .distantPast

    /// Fresh tab (mints a new sessionId, resume off).
    convenience init(id: UUID = UUID(), name: String, cwd: URL, kind: SessionKind = .sona, url: URL? = nil) {
        self.init(id: id, name: name, cwd: cwd, kind: kind, url: url,
                  sessionId: UUID().uuidString.lowercased(), resume: false)
    }

    /// Variant used when bootstrapping from the persistence table on app
    /// launch: caller supplies the prior `sessionId` so Claude Code can
    /// re-attach with `--resume`. Setting `resume: true` flips the spawn
    /// path to use `--resume <sessionId>` instead of `--session-id`.
    convenience init(id: UUID, name: String, cwd: URL, sessionId: String, resume: Bool,
                     kind: SessionKind = .sona, url: URL? = nil) {
        self.init(id: id, name: name, cwd: cwd, kind: kind, url: url,
                  sessionId: sessionId, resume: resume)
    }

    /// Designated init — builds the content backend (terminal or webview)
    /// according to `kind` and wires up the matching delegate.
    private init(id: UUID, name: String, cwd: URL, kind: SessionKind, url: URL?,
                 sessionId: String, resume: Bool) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.url = url
        self.sessionId = sessionId
        self.resume = resume

        switch kind {
        case .sona, .terminal:
            let tv = DropEnabledTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            tv.applyWarmChrome()
            // NOTE: warm text colors are enabled in spawn(), *after*
            // resetToInitialState() — that reset wipes the terminal palette, so
            // applying it here would be undone before the shell runs.
            self.terminal = tv
            self.webView = nil
        case .webview:
            let config = WKWebViewConfiguration()
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
            self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
            self.terminal = nil
        }

        super.init()
        terminal?.processDelegate = self
        webView?.navigationDelegate = self
    }

    /// Used by the rail's Restart button after a failed --resume (e.g. the
    /// session file at ~/.claude/sessions/<sessionId>.json was pruned).
    /// Flipping `resume` to false on Restart means the next spawn uses
    /// `--session-id` and starts a fresh conversation with the same
    /// sessionId, keeping the persistence row stable across the retry.
    func clearResumeFlag() { resume = false }

    // MARK: - Lifecycle

    func spawn() {
        switch kind {
        case .sona: spawnSona()
        case .terminal: spawnTerminal()
        case .webview: loadWeb()
        }
    }

    /// Load (or reload) the target URL in the WKWebView. State is driven by
    /// the navigation delegate: `.starting` here, `.running` on didFinish,
    /// `.spawnFailed` on a load error.
    private func loadWeb() {
        guard let webView else { return }
        guard let url else {
            state = .spawnFailed(message: "No URL set for this web session")
            return
        }
        state = .starting
        lastSpawnAt = Date()
        webView.load(URLRequest(url: url))
    }

    /// Launch a plain interactive login shell — no Claude, no MCP, no
    /// auto-confirm. Uses `$SHELL` (fallback `/bin/zsh`) and the same env/PATH
    /// the Sona path builds, so tools on PATH and the usual tokens are present.
    private func spawnTerminal() {
        guard let termView = terminal else { return }
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        // omitLegacyRole: true — SONATA_ROLE=session is meaningless for a bare
        // shell and we don't want it leaking into the user's environment.
        let env = InteractiveSessionTab.buildEnvironment(sessionId: sessionId, omitLegacyRole: true)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        termView.getTerminal().resetToInitialState()
        (termView as? DropEnabledTerminalView)?.enableWarmTerminalColors()

        guard FileManager.default.isExecutableFile(atPath: shell) else {
            state = .spawnFailed(message: "Shell not found at \(shell)")
            return
        }

        lastSpawnAt = Date()
        termView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            currentDirectory: cwd.path
        )
        state = .running
    }

    private func spawnSona() {
        guard let termView = terminal else { return }
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        // Per plan §6: opt-in in-proc MCP. SessionKey is a stable prefix
        // of the existing UUID so it satisfies MCPSessionKey.isValid
        // (1-128 [A-Za-z0-9_-]). Flag unset → behaviour unchanged.
        let inProcExtras = MCPSpawn.extraArgsForInProcMCP(
            sessionKey: mcpSessionKey,
            role: .interactive,
            slotLabel: "interactive"
        )
        let env = InteractiveSessionTab.buildEnvironment(sessionId: sessionId, omitLegacyRole: inProcExtras != nil)

        var args: [String] = []
        // `--resume <id>` and `--session-id <id>` are mutually exclusive in
        // Claude Code (claude rejects the combo unless --fork-session is set,
        // per ~/.zshrc sona launcher comment). When restoring a persisted
        // tab we want to re-attach to the prior conversation, so use
        // --resume. Fresh tabs (or post-Restart fallbacks) get --session-id.
        if resume {
            args.append(contentsOf: ["--resume", sessionId])
        } else {
            args.append(contentsOf: ["--session-id", sessionId])
        }
        args.append("--dangerously-skip-permissions")
        args.append(contentsOf: ["--dangerously-load-development-channels", "server:sonata-bridge"])
        args.append(contentsOf: ["--model", "claude-opus-4-7"])
        if let extras = inProcExtras {
            args.append(contentsOf: extras)
        }

        termView.getTerminal().resetToInitialState()
        (termView as? DropEnabledTerminalView)?.enableWarmTerminalColors()

        let binary = InteractiveSessionTab.claudeBinary
        guard FileManager.default.isExecutableFile(atPath: binary) || binary == "claude" else {
            state = .spawnFailed(message: "Claude binary not found at \(binary)")
            return
        }

        lastSpawnAt = Date()
        termView.startProcess(
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
                    self.terminal?.send(txt: "\r")
                }
            }
        }
    }

    func terminate() {
        terminal?.terminate()
        webView?.stopLoading()
    }

    /// Make this session's content the window's first responder so the user
    /// can type immediately without clicking. Only meaningful for terminal-
    /// backed sessions; web sessions handle their own focus on click.
    func focusContent() {
        guard kind.isTerminalBacked, let termView = terminal else { return }
        DispatchQueue.main.async {
            termView.window?.makeFirstResponder(termView)
        }
    }

    /// Insert dropped file paths into a terminal-backed session (forwarded from
    /// the app-level drop catcher). No-op for web sessions.
    func insertDroppedPaths(_ paths: [String]) {
        (terminal as? DropEnabledTerminalView)?.insertPaths(paths)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    // MARK: - WKNavigationDelegate (web sessions)

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.state = .running }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Self.handleWebLoadFailure(error, on: self)
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Self.handleWebLoadFailure(error, on: self)
    }

    /// Mark the session failed on a real load error, but ignore `cancelled`
    /// (-999) — WebKit reports that for benign superseded navigations (e.g. a
    /// redirect or a quick reload), and flipping the session red on those would
    /// be wrong.
    private nonisolated static func handleWebLoadFailure(_ error: any Error, on tab: InteractiveSessionTab?) {
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        Task { @MainActor [weak tab] in tab?.state = .spawnFailed(message: error.localizedDescription) }
    }

    nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        let code = exitCode
        Task { @MainActor [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastSpawnAt)
            // Quick-exit in --resume mode = the session file claude was
            // trying to re-attach to didn't exist (or was empty). Most
            // commonly: the prior tab spawned but never had any user
            // input, so claude never wrote a history file. Silently
            // re-spawn with --session-id (fresh conversation, same
            // sessionId so the persistence row stays valid).
            if self.resume, elapsed < 3.0 {
                self.resume = false
                self.state = .starting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.spawn()
                }
                return
            }
            self.state = .stopped(exitCode: code)
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

    /// DB pool used to read / write the persistence table (migration v14).
    /// Set by `bootstrap(dbPool:)`; nil = persistence disabled (no-op for all
    /// store calls, so old tests / preview code keeps working).
    private var dbPool: DatabasePool?
    private var bootstrapped = false

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    // MARK: - Persistence bootstrap

    /// Load persisted sessions from the v14 `interactiveSessions` table and
    /// recreate each tab with --resume. Returns the count of tabs that were
    /// restored; callers (ContentView's .onAppear) decide whether to
    /// auto-spawn a "Sonata Default" based on the result (zero → yes,
    /// non-zero → no).
    ///
    /// Idempotent — subsequent calls are a no-op so .onAppear can fire
    /// multiple times without duplicating tabs.
    @discardableResult
    func bootstrap(dbPool: DatabasePool) -> Int {
        guard !bootstrapped else { return tabs.count }
        bootstrapped = true
        self.dbPool = dbPool

        let rows = InteractiveSessionsStore.loadAll(dbPool: dbPool)
        guard !rows.isEmpty else { return 0 }

        var lastActiveId: UUID?
        for row in rows {
            guard let uuid = UUID(uuidString: row.id) else { continue }
            let kind = SessionKind(rawValue: row.kind) ?? .sona
            let tab = InteractiveSessionTab(
                id: uuid,
                name: row.name,
                cwd: URL(fileURLWithPath: row.cwd),
                sessionId: row.sessionId,
                // Only Sona sessions re-attach to a prior Claude conversation;
                // terminals and web sessions have nothing to --resume.
                resume: kind == .sona,
                kind: kind,
                url: row.url.flatMap { URL(string: $0) }
            )
            tabs.append(tab)
            if row.wasActive == 1 { lastActiveId = uuid }
        }
        // Pick the previously-active tab if we have one, else the first.
        if let lastActiveId, tabs.contains(where: { $0.id == lastActiveId }) {
            activeTabId = lastActiveId
            self.lastActiveTabId = lastActiveId
        } else if let first = tabs.first {
            activeTabId = first.id
            self.lastActiveTabId = first.id
        }
        // Spawn each tab on the next runloop tick so the view model is
        // settled before the SwiftTerm pty starts and starts firing
        // process-state callbacks.
        let restoredTabs = tabs
        DispatchQueue.main.async {
            for tab in restoredTabs {
                tab.spawn()
            }
        }
        return tabs.count
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
        return addTab(name: name, cwd: cwd)
    }

    /// Variant used by the rail-side "New Session" sheet: caller supplies the
    /// display name and working directory directly (cwd is typically picked
    /// from NSOpenPanel). The process is spawned with currentDirectory =
    /// cwd.path, same as the default-path variant. Trims the name and falls
    /// back to a "Session <N>" auto-name if it's empty.
    @discardableResult
    func addTab(name: String, cwd: URL, kind: SessionKind = .sona, url: URL? = nil) -> InteractiveSessionTab {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Session \(nextSessionIndex())" : trimmed
        let tab = InteractiveSessionTab(name: finalName, cwd: cwd, kind: kind, url: url)
        tabs.append(tab)
        persistTab(tab, position: tabs.count - 1)
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
        if let pool = dbPool {
            InteractiveSessionsStore.delete(dbPool: pool, id: tab.id.uuidString.lowercased())
            // Renumber survivors so positions stay contiguous and ordered
            // for the next bootstrap.
            InteractiveSessionsStore.updatePositions(
                dbPool: pool,
                ids: tabs.map { $0.id.uuidString.lowercased() }
            )
        }

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
        if let pool = dbPool {
            InteractiveSessionsStore.updateName(
                dbPool: pool,
                id: tab.id.uuidString.lowercased(),
                name: trimmed
            )
        }
    }

    func selectTab(id: UUID) {
        activeTabId = id
        lastActiveTabId = id
        if let pool = dbPool {
            InteractiveSessionsStore.setActive(dbPool: pool, id: id.uuidString.lowercased())
        }
        // Drop focus into the selected session so typing lands immediately
        // (terminal-backed kinds only; focusContent no-ops for web).
        tabs.first(where: { $0.id == id })?.focusContent()
    }

    /// Focus the currently-active session's content. Called when the Sessions
    /// section appears so the user can start typing without clicking.
    func focusActiveContent() {
        guard let id = activeTabId else { return }
        tabs.first(where: { $0.id == id })?.focusContent()
    }

    /// Route dropped file paths (from the app-level drop catcher) to the
    /// active session. No-op when nothing is active or it's a web session.
    func handleDroppedPaths(_ paths: [String]) {
        guard let id = activeTabId else { return }
        tabs.first(where: { $0.id == id })?.insertDroppedPaths(paths)
    }

    func restartTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // If the original --resume failed (session file pruned, etc.), flip
        // the flag so the next spawn falls back to --session-id and starts
        // a fresh conversation under the same sessionId. The persistence
        // row stays put, so future restarts only need to fall through this
        // path once.
        tab.clearResumeFlag()
        tab.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            tab.spawn()
        }
    }

    /// Persist a freshly-created tab to the v14 table. Called from addTab
    /// after the tab is appended to `tabs`. No-op if dbPool isn't set yet
    /// (early code paths before bootstrap).
    private func persistTab(_ tab: InteractiveSessionTab, position: Int) {
        guard let pool = dbPool else { return }
        InteractiveSessionsStore.upsert(
            dbPool: pool,
            id: tab.id.uuidString.lowercased(),
            sessionId: tab.sessionId,
            name: tab.name,
            cwd: tab.cwd.path,
            position: position,
            wasActive: tab.id == activeTabId,
            kind: tab.kind.rawValue,
            url: tab.url?.absoluteString
        )
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
