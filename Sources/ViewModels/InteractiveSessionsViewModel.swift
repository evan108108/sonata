import Foundation
import GRDB
import SwiftTerm
import AppKit
import SwiftUI
import WebKit
import CryptoKit

enum InteractiveSessionState: Equatable {
    case starting
    case running
    case stopped(exitCode: Int32?)
    case spawnFailed(message: String)
}

/// Governance lifecycle of a webview session — orthogonal to the live render
/// `InteractiveSessionState`. A `live` session has an instantiated WKWebView; a
/// `suspended` one has had it deallocated (WebContent process freed) but keeps
/// its WKWebsiteDataStore on disk + its registry row, so it resumes on next
/// drive/focus.
enum WebviewLifecycle: String, Codable {
    case live
    case suspended
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

    /// Bridge sessionKey of the agent that created this webview session.
    /// Drives Agent Webviews tree grouping + owning-agent-death auto-close.
    /// nil for sona/terminal and for user-created webviews from the UI.
    let ownerAgentId: String?

    /// Cookie/data-store partition NAME. nil ⇒ shared WKWebsiteDataStore.default().
    /// Bound to the WKWebViewConfiguration at build time; immutable per session.
    let partition: String?

    /// True for headless sessions: driveable + persisted + shown in the tree,
    /// but not auto-selected and filtered out of the in-rail Sessions strip.
    /// Cleared when the session is brought to the foreground via selectTab,
    /// so session_list/UI reflect that it's no longer headless.
    @Published var background: Bool

    /// Lifecycle status for webview sessions. Mirrors the persisted `status`.
    /// `.starting`/`.running`/etc. on `state` is the live render state; this is
    /// the governance state the sweeper and tree read.
    @Published var lifecycle: WebviewLifecycle = .live

    /// Epoch ms of the last drive/navigation. Sweeper reads this for idle math.
    @Published var lastActivityAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    /// The WKWebsiteDataStore this session's WKWebView binds to. Built once
    /// from `partition` and reused across suspend/resume so cookies/logins
    /// survive a WebContent-process teardown. `.default()` (shared) when
    /// `partition == nil`; an isolated forIdentifier: store otherwise.
    private let dataStore: WKWebsiteDataStore

    // Exactly one of these is non-nil, selected by `kind`. `contentView`
    // exposes whichever to the SwiftUI container. `webView` is a `var` (not a
    // `let`) so suspend() can deallocate it — freeing the WebContent process —
    // and resume() can rebuild it against the same WKWebsiteDataStore.
    let terminal: LocalProcessTerminalView?
    private(set) var webView: WKWebView?

    /// The NSView to mount for this session — terminal or webview.
    /// Returns nil for suspended webview sessions (both terminal and webView
    /// are deallocated to free the WebContent process). Callers must skip nil
    /// entries rather than force-unwrapping.
    var contentView: NSView? {
        if let terminal { return terminal }
        if let webView { return webView }
        return nil
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

    /// True for a bootstrap-restored Terminal tab that should replay its saved
    /// scrollback log once, before the fresh shell starts. One-shot (cleared
    /// after the first spawn so a manual Restart doesn't re-replay).
    var shouldReplayScrollback = false

    /// Per-session scrollback log file. Terminal sessions tee their output here
    /// so the on-screen history survives a restart. Keyed by the stable tab id.
    static func scrollbackLogURL(for id: UUID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sonata/scrollback/\(id.uuidString.lowercased()).log")
    }

    /// Resolve a partition name to a data store. nil ⇒ the shared default jar
    /// (log into Gmail once, every agent inherits it). A non-nil name ⇒ an
    /// isolated persistent store keyed by a DETERMINISTIC UUID derived from the
    /// name (UUIDv5-style, namespaced), so the same partition always reopens the
    /// same cookies. macOS 14+ (Package.swift platforms .v14), so forIdentifier:
    /// is available.
    static func makeDataStore(partition: String?) -> WKWebsiteDataStore {
        guard let partition, !partition.isEmpty else { return .default() }
        return WKWebsiteDataStore(forIdentifier: stableUUID(forPartition: partition))
    }

    /// Deterministic UUIDv5 (SHA-256 truncated, RFC-4122 variant/version bits set)
    /// over a fixed namespace + the partition name. Same name ⇒ same UUID.
    static func stableUUID(forPartition name: String) -> UUID {
        let namespace = "sonata.webview.partition"  // fixed salt
        var hasher = SHA256()
        hasher.update(data: Data(namespace.utf8))
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC-4122 variant
        let uuid = (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                    bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])
        return UUID(uuid: uuid)
    }

    /// Fresh tab (mints a new sessionId, resume off).
    convenience init(id: UUID = UUID(), name: String, cwd: URL, kind: SessionKind = .sona,
                     url: URL? = nil, ownerAgentId: String? = nil, partition: String? = nil,
                     background: Bool = false) {
        self.init(id: id, name: name, cwd: cwd, kind: kind, url: url,
                  sessionId: UUID().uuidString.lowercased(), resume: false,
                  ownerAgentId: ownerAgentId, partition: partition, background: background,
                  materializeWebView: !background)  // background sessions start suspended
    }

    /// Variant used when bootstrapping from the persistence table on app
    /// launch: caller supplies the prior `sessionId` so Claude Code can
    /// re-attach with `--resume`. Setting `resume: true` flips the spawn
    /// path to use `--resume <sessionId>` instead of `--session-id`.
    convenience init(id: UUID, name: String, cwd: URL, sessionId: String, resume: Bool,
                     kind: SessionKind = .sona, url: URL? = nil,
                     ownerAgentId: String? = nil, partition: String? = nil,
                     background: Bool = false, lifecycle: WebviewLifecycle = .live,
                     materializeWebView: Bool) {
        self.init(id: id, name: name, cwd: cwd, kind: kind, url: url,
                  sessionId: sessionId, resume: resume,
                  ownerAgentId: ownerAgentId, partition: partition, background: background,
                  materializeWebView: materializeWebView)
        self.lifecycle = lifecycle
    }

    /// Designated init — builds the content backend (terminal or webview)
    /// according to `kind` and wires up the matching delegate.
    private init(id: UUID, name: String, cwd: URL, kind: SessionKind, url: URL?,
                 sessionId: String, resume: Bool,
                 ownerAgentId: String? = nil, partition: String? = nil,
                 background: Bool = false, materializeWebView: Bool = true) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.url = url
        self.sessionId = sessionId
        self.resume = resume
        self.ownerAgentId = ownerAgentId
        self.partition = partition
        self.background = background
        self.dataStore = InteractiveSessionTab.makeDataStore(partition: partition)

        switch kind {
        case .sona, .terminal:
            let tv = DropEnabledTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            tv.applyWarmChrome()
            // NOTE: warm text colors are enabled in spawn(), *after*
            // resetToInitialState() — that reset wipes the terminal palette, so
            // applying it here would be undone before the shell runs.
            // Capture scrollback for plain Terminal sessions only (Sona has its
            // own --resume history; Workers/Supervisor don't persist output).
            if kind == .terminal {
                tv.scrollbackLogURL = Self.scrollbackLogURL(for: id)
            }
            self.terminal = tv
            self.webView = nil
        case .webview:
            self.terminal = nil
            self.webView = materializeWebView
                ? InteractiveSessionTab.makeWebView(dataStore: dataStore)
                : nil
            self.lifecycle = materializeWebView ? .live : .suspended
        }

        super.init()
        terminal?.processDelegate = self
        webView?.navigationDelegate = self
    }

    /// Build a WKWebView bound to the given data store. Factored out of init so
    /// resume() can rebuild it identically. The data store is set on the config
    /// BEFORE construction — it can't be swapped on a live WKWebView, which is
    /// why partition is a create-time, immutable property.
    static func makeWebView(dataStore: WKWebsiteDataStore) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        // Present a full desktop-Safari UA. The bare WKWebView default omits the
        // "Version/.. Safari/.." suffix, and some sites sniff for it and serve
        // degraded or blocked content — a complete Safari UA hardens scraping.
        wv.customUserAgent = safariUserAgent
        return wv
    }

    /// Full desktop-Safari user agent applied to every session's WKWebView.
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

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
        termView.getTerminal().changeScrollback(5000)  // keep more history than the 500 default
        (termView as? DropEnabledTerminalView)?.enableWarmTerminalColors()

        guard FileManager.default.isExecutableFile(atPath: shell) else {
            state = .spawnFailed(message: "Shell not found at \(shell)")
            return
        }

        // Replay prior scrollback into the (just-reset) terminal before the new
        // shell starts, so a restored session shows its history above the fresh
        // prompt. One-shot — only for a bootstrap-restored tab.
        if shouldReplayScrollback {
            shouldReplayScrollback = false
            replayScrollback(into: termView)
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

    /// Feed the saved scrollback log into the terminal as read-only history.
    /// Feeding bypasses dataReceived, so it isn't re-captured; the live shell's
    /// output then appends to the same log after this.
    private func replayScrollback(into termView: LocalProcessTerminalView) {
        let url = InteractiveSessionTab.scrollbackLogURL(for: id)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let tail = Array(data.suffix(DropEnabledTerminalView.scrollbackMaxBytes))
        // Replay a flattened transcript: keep text + newlines + color (SGR), but
        // strip cursor-movement and erase sequences. Re-running an interactive
        // shell's raw control codes at a different terminal size makes its prompt
        // redraws erase the replayed history — a flat colored dump renders the
        // full output reliably.
        let flat = InteractiveSessionTab.flattenForReplay(tail)
        termView.feed(byteArray: flat[...])
        termView.feed(text: "\r\n\u{1b}[2m── session restored ──\u{1b}[0m\r\n")
    }

    /// Strip cursor-positioning / erase control from a captured terminal byte
    /// stream, keeping printable bytes, newline/CR/tab, and SGR (color) escapes.
    /// Drops other CSI sequences (cursor moves, erases), OSC sequences (titles),
    /// and other escapes — leaving a linear, colored transcript safe to replay.
    nonisolated static func flattenForReplay(_ bytes: [UInt8]) -> [UInt8] {
        let esc: UInt8 = 0x1b
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b != esc {
                // Keep printable (≥ 0x20, excl. DEL), plus LF / CR / TAB.
                if b == 0x0a || b == 0x0d || b == 0x09 || (b >= 0x20 && b != 0x7f) {
                    out.append(b)
                }
                i += 1
                continue
            }
            // ESC sequence.
            guard i + 1 < n else { break }
            let kind = bytes[i + 1]
            if kind == 0x5b { // '[' → CSI: scan to final byte (0x40...0x7e)
                var j = i + 2
                while j < n, !(bytes[j] >= 0x40 && bytes[j] <= 0x7e) { j += 1 }
                guard j < n else { break }
                if bytes[j] == 0x6d { out.append(contentsOf: bytes[i...j]) } // 'm' = SGR, keep
                i = j + 1
            } else if kind == 0x5d { // ']' → OSC: drop until BEL or ST (ESC \)
                var j = i + 2
                while j < n {
                    if bytes[j] == 0x07 { j += 1; break }
                    if bytes[j] == esc, j + 1 < n, bytes[j + 1] == 0x5c { j += 2; break }
                    j += 1
                }
                i = j
            } else {
                // Other escape (charset selection, etc.) — drop ESC + next byte.
                i += 2
            }
        }
        return out
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
        termView.getTerminal().changeScrollback(5000)  // keep more history than the 500 default
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

    // MARK: - Webview suspend / resume (governance)

    /// Free the WebContent process: stop loading, drop the navigation delegate,
    /// deallocate the WKWebView. The WKWebsiteDataStore (on disk) + the registry
    /// row are retained, so resume() rebuilds an identical session. No-op for
    /// terminal-backed kinds or an already-suspended webview.
    func suspend() {
        guard kind == .webview, lifecycle == .live else { return }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        lifecycle = .suspended
        state = .stopped(exitCode: nil)
    }

    /// Rebuild the WKWebView against the SAME data store and reload the last
    /// URL. No-op if already live. Called transparently by any drive verb and
    /// by focus (spy/peek). Cookies/logins survive because they live in the
    /// persistent data store, not the WKWebView.
    ///
    /// Named `resumeWebView` (not `resume`) to avoid colliding with the
    /// existing `resume: Bool` --resume flag stored property.
    func resumeWebView() {
        guard kind == .webview, lifecycle == .suspended else { return }
        let wv = InteractiveSessionTab.makeWebView(dataStore: dataStore)
        wv.navigationDelegate = self
        self.webView = wv
        lifecycle = .live
        if let url {
            state = .starting
            lastSpawnAt = Date()
            wv.load(URLRequest(url: url))
        } else {
            state = .running
        }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .running
            let committed = webView.url?.absoluteString
            self.lastActivityAt = Int64(Date().timeIntervalSince1970 * 1000)
            InteractiveSessionsViewModel.shared.recordWebviewActivity(
                tabId: self.id, lastURL: committed, at: self.lastActivityAt)
        }
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
            let isWeb = (kind == .webview)
            let tab = InteractiveSessionTab(
                id: uuid,
                name: row.name,
                cwd: URL(fileURLWithPath: row.cwd),
                sessionId: row.sessionId,
                // Only Sona sessions re-attach to a prior Claude conversation;
                // terminals and web sessions have nothing to --resume.
                resume: kind == .sona,
                kind: kind,
                url: row.url.flatMap { URL(string: $0) },
                ownerAgentId: row.ownerAgentId,
                partition: row.partition,
                background: row.background == 1,
                // Webviews come back SUSPENDED (spec §9): no WKWebView until
                // first focus/drive. sona/terminal restore live as before.
                lifecycle: isWeb ? .suspended : .live,
                materializeWebView: false              // webviews never build the WKWebView here
            )
            // Restored Terminal sessions replay their saved scrollback once.
            tab.shouldReplayScrollback = (kind == .terminal)
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
        // Spawn only terminal-backed sessions; webviews stay suspended until
        // first focus/drive resumes them.
        let restoredTabs = tabs
        DispatchQueue.main.async {
            for tab in restoredTabs where tab.kind.isTerminalBacked {
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

    /// Create a webview session (the MCP `session_create` backend). When
    /// `background` is true the session is created suspended, NOT selected, and
    /// filtered out of the in-rail strip — it still persists + drives + shows in
    /// the Agent Webviews tree. Visible (non-background) sessions materialize a
    /// live WKWebView and load `url` immediately.
    @discardableResult
    func addWebviewSession(ownerAgentId: String?, url: URL?, partition: String?,
                           background: Bool, name: String? = nil) -> InteractiveSessionTab {
        let finalName = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? (url?.host ?? "Web \(nextSessionIndex())")
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let cwd = URL(fileURLWithPath: "\(home)/.sonata/session/web")
        let tab = InteractiveSessionTab(
            name: finalName, cwd: cwd, kind: .webview, url: url,
            ownerAgentId: ownerAgentId, partition: partition, background: background)
        tabs.append(tab)
        persistTab(tab, position: tabs.count - 1)
        if !background {
            selectTab(id: tab.id)
            DispatchQueue.main.async { tab.spawn() }   // loadWeb()
        } else if url != nil {
            // Background + initial URL: materialize headlessly and kick off the
            // load now (mirrors the foreground path minus selectTab) so the
            // first drive verb sees the page instead of about:blank. The sweeper
            // idle-suspends it later; a background session WITHOUT a url stays
            // lazily suspended until first driven.
            DispatchQueue.main.async { self.resumeTab(id: tab.id) }
        }
        return tab
    }

    /// Look up a webview tab by its public session id (the persistence PK =
    /// tab.id UUID string, lowercased). Used by the driver/MCP layer.
    func webviewTab(id sid: String) -> InteractiveSessionTab? {
        tabs.first { $0.kind == .webview && $0.id.uuidString.lowercased() == sid }
    }

    /// Count of LIVE webview WKWebViews — the sweeper's ceiling check.
    var liveWebviewCount: Int {
        tabs.filter { $0.kind == .webview && $0.lifecycle == .live }.count
    }

    func suspendTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.suspend()
        dbPool.map { InteractiveSessionsStore.updateStatus(dbPool: $0, id: id.uuidString.lowercased(), status: "suspended") }
    }

    func resumeTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.resumeWebView()
        dbPool.map { InteractiveSessionsStore.updateStatus(dbPool: $0, id: id.uuidString.lowercased(), status: "live") }
    }

    /// Called from the nav delegate; persists last URL + activity.
    func recordWebviewActivity(tabId: UUID, lastURL: String?, at ms: Int64) {
        dbPool.map {
            InteractiveSessionsStore.updateLastURLAndActivity(
                dbPool: $0, id: tabId.uuidString.lowercased(), url: lastURL, at: ms)
        }
    }

    /// Close every webview session owned by `agentId`. Wired to MCP session
    /// eviction (owning-agent death) — see §6.4.
    func closeOwnedBy(agentId: String) {
        let doomed = tabs.filter { $0.kind == .webview && $0.ownerAgentId == agentId }.map(\.id)
        for id in doomed { closeTab(id: id) }
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        tab.terminate()
        if tab.kind == .terminal { handleScrollbackOnClose(tab) }
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

    /// On closing a Terminal session: if its scrollback log holds meaningful
    /// activity, dispatch a background task to summarize it into memory and then
    /// delete the log. Trivial/empty logs are just deleted inline.
    private func handleScrollbackOnClose(_ tab: InteractiveSessionTab) {
        let logURL = InteractiveSessionTab.scrollbackLogURL(for: tab.id)
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        guard bytes > 0 else { return }
        if bytes > 512 {
            // Leave the log on disk — the dispatched task reads it, writes the
            // memory, then deletes it itself.
            enqueueScrollbackSummary(name: tab.name, cwd: tab.cwd.path, logURL: logURL)
        } else {
            try? FileManager.default.removeItem(at: logURL)  // nothing worth summarizing
        }
    }

    /// Insert a `pending` task the dispatcher hands to a bridge worker: read the
    /// scrollback log, write a concise memory of what the session did, then
    /// delete the log. (The worker has mem_store + file tools.)
    private func enqueueScrollbackSummary(name: String, cwd: String, logURL: URL) {
        guard let pool = dbPool else { return }
        let path = logURL.path
        let prompt = """
        A plain terminal session in the Sonata app was just closed. Its full \
        on-screen output (scrollback) is saved at:
          \(path)

        The session was named "\(name)" and ran in directory: \(cwd)

        Do the following:
        1. Read the scrollback log file at the path above.
        2. If it contains meaningful activity, write ONE concise memory \
        summarizing what happened — the notable commands run, what they \
        accomplished, any errors or important output, and the overall outcome. \
        Use the mem_store tool with type "conversation_summary", tags \
        ["terminal-session","scrollback-summary"], and include the session name \
        in the content. Keep it tight (a few sentences) — a record of what was \
        done, not a transcript.
        3. If the log is empty or only a shell prompt with no real activity, \
        skip the memory.
        4. After step 2 (or 3), delete the log file: rm -f "\(path)"

        The log may contain terminal escape codes; ignore the formatting noise \
        and focus on the actual commands and output.
        """
        let taskId = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO tasks (id, title, prompt, status, priority, assignedTo, source, workingDir, model, maxTurns, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'pending', 'low', 'scheduler', 'session-scrollback', ?, ?, ?, ?, ?)
                """, arguments: [
                    taskId,
                    "Summarize terminal session: \(name)",
                    prompt,
                    NSHomeDirectory(),
                    "claude-sonnet-4-6",
                    20,
                    now,
                    now,
                ])
            }
        } catch {
            NSLog("[scrollback] failed to enqueue summary task: \(error)")
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
        // Bringing a headless (background) session to the foreground un-hides it:
        // clear the flag + persist so session_list and the rail stop reporting
        // it as background once focus mounts it.
        if let tab = tabs.first(where: { $0.id == id }), tab.background {
            tab.background = false
            dbPool.map {
                InteractiveSessionsStore.updateBackground(
                    dbPool: $0, id: id.uuidString.lowercased(), background: false)
            }
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
            url: tab.url?.absoluteString,
            ownerAgentId: tab.ownerAgentId,
            partition: tab.partition,
            status: tab.lifecycle.rawValue,
            lastActivityAt: tab.lastActivityAt,
            background: tab.background
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
