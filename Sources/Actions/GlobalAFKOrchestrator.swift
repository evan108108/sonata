import Foundation
import Logging

/// Side-effects that fire when Global AFK flips: broadcast the directive to
/// every connected interactive + supervisor session via DM, and send ONE
/// kickoff email with per-session mailto links so Evan can reply to any
/// session without copy-pasting tokens.
///
/// Separated from `GlobalAFKController` so the controller stays narrow (state
/// + persistence) and the side-effects stay testable / replaceable. Subscribes
/// to the `.sonataGlobalAFKChanged` notification posted by the controller.
///
/// Workers are deliberately excluded from the broadcast — they're already
/// event-driven async and have no AskUserQuestion surface to switch.
actor GlobalAFKOrchestrator {
    static let shared = GlobalAFKOrchestrator()

    /// Where the kickoff email is sent. Falls back to the hardcoded address
    /// if the SONATA_USER_EMAIL env var isn't set. Matches the existing AFK
    /// skill convention.
    private static let userEmailAddress: String = {
        ProcessInfo.processInfo.environment["SONATA_USER_EMAIL"] ?? "evan108108@gmail.com"
    }()

    private static let sonaInbox = "sona@agentmail.to"

    private let logger: Logging.Logger
    private var notifObserver: NSObjectProtocol?
    private var attachObserver: NSObjectProtocol?

    private init() {
        var log = Logging.Logger(label: "sonata.globalafk.orchestrator")
        log.logLevel = .info
        self.logger = log
    }

    /// Subscribe to controller flips. Called once from SonataApp boot, after
    /// `GlobalAFKController.shared.bootstrap` runs. Idempotent.
    func start() {
        if notifObserver != nil { return }
        notifObserver = NotificationCenter.default.addObserver(
            forName: .sonataGlobalAFKChanged,
            object: nil,
            queue: nil
        ) { note in
            guard let enabled = note.userInfo?["enabled"] as? Bool else { return }
            Task.detached { [weak self] in
                await self?.handleFlip(enabled: enabled)
            }
        }
        // Push directive at sessions that attach AFTER global AFK is already
        // on — otherwise the toggle leaks over time as new sessions start.
        attachObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("sonataMCPSessionAttached"),
            object: nil,
            queue: nil
        ) { note in
            guard let sessionKey = note.userInfo?["sessionKey"] as? String,
                  let roleStr = note.userInfo?["role"] as? String else { return }
            Task.detached { [weak self] in
                await self?.handleSessionAttached(sessionKey: sessionKey, roleStr: roleStr)
            }
        }
        logger.info("global AFK orchestrator subscribed (flip + attach)")
    }

    private func handleSessionAttached(sessionKey: String, roleStr: String) async {
        // Workers don't get the directive (already event-driven async).
        guard roleStr == "interactive" || roleStr == "supervisor" else { return }
        let isOn = await MainActor.run { GlobalAFKController.shared.isEnabled }
        guard isOn else { return }
        guard let reg = MCPSessionRegistry.shared else { return }
        // Register this late-joiner under its global token too, mirroring
        // the broadcast path — otherwise replies addressed to it via the
        // kickoff email's mailto links fall through to a generic worker.
        let token = "global-\(sessionKey.prefix(8))"
        AFKRegistry.shared.register(token: String(token), sessionId: sessionKey)
        let messageId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
        let pushed = await reg.deliverDM(
            target: sessionKey,
            messageId: messageId,
            body: directiveBody(action: "enter"),
            fromSessionId: "sonata-global-afk",
            context: "global_afk_directive_late_join",
            metaJson: directiveMeta(action: "enter"),
            sentAtMs: Int64(Date().timeIntervalSince1970 * 1000.0)
        )
        if pushed {
            logger.info("global AFK late-join directive pushed to new session \(sessionKey) (\(roleStr))")
        }
    }

    /// Top-level handler — broadcasts the directive to all sessions and (on
    /// enable transitions) sends the kickoff email. Failure in one side-effect
    /// doesn't block the other: we want the broadcast to land even if email
    /// fails, and vice versa.
    private func handleFlip(enabled: Bool) async {
        let action = enabled ? "enter" : "exit"
        let snaps = await collectTargetSessions()
        logger.info("global AFK flip: action=\(action) targets=\(snaps.count)")

        // Register/unregister each session under its global token in
        // AFKRegistry so EmailHandler can route [AFK:global-XXXX] replies
        // straight to the right session. Without this, inbound replies fall
        // through to the regular email-handling path and a random worker
        // processes them instead of the addressed session.
        for snap in snaps {
            let token = "global-\(snap.sessionKey.prefix(8))"
            if enabled {
                AFKRegistry.shared.register(token: String(token), sessionId: snap.sessionKey)
            } else {
                AFKRegistry.shared.unregister(token: String(token))
            }
        }

        // Broadcast directive to each session.
        var deliveredCount = 0
        let directiveMetaJson = directiveMeta(action: action)
        guard let reg = MCPSessionRegistry.shared else { return }
        for snap in snaps {
            let messageId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
            let pushed = await reg.deliverDM(
                target: snap.sessionKey,
                messageId: messageId,
                body: directiveBody(action: action),
                fromSessionId: "sonata-global-afk",
                context: "global_afk_directive",
                metaJson: directiveMetaJson,
                sentAtMs: Int64(Date().timeIntervalSince1970 * 1000.0)
            )
            if pushed { deliveredCount += 1 }
        }
        logger.info("global AFK directives pushed: \(deliveredCount)/\(snaps.count)")

        // Send kickoff email on enable transitions only — disabling doesn't
        // need an email (you toggled it off, you know it's off).
        if enabled {
            await sendKickoffEmail(targets: snaps)
        }
    }

    /// Sessions that should receive the directive. Interactive + supervisor;
    /// excludes workers (already event-driven async).
    private func collectTargetSessions() async -> [MCPSessionRegistry.SessionSnapshot] {
        guard let reg = MCPSessionRegistry.shared else { return [] }
        let snaps = await reg.snapshot()
        return snaps.filter { snap in
            snap.hasSSE && (snap.role == .interactive || snap.role == .supervisor)
        }
    }

    /// DM body — readable plain text, in case the model glances at it. The
    /// metaJson is the authoritative signal; this body is documentation.
    private func directiveBody(action: String) -> String {
        switch action {
        case "enter":
            return "[GLOBAL AFK ENTER] Evan is stepping away. Switch to AFK mode now: route any questions to email per the /afk skill protocol. Don't ask via AskUserQuestion until you receive a [GLOBAL AFK EXIT] directive."
        case "exit":
            return "[GLOBAL AFK EXIT] Evan is back at the keyboard. Exit AFK mode: you can resume using AskUserQuestion. Any in-flight AFK email threads remain valid; finish them naturally."
        default:
            return "[GLOBAL AFK \(action.uppercased())]"
        }
    }

    /// metaJson the session reads from the channel event. event_type is the
    /// authoritative key the model's CLAUDE.md tells it to look for.
    private func directiveMeta(action: String) -> String {
        let dict: [String: Any] = [
            "event_type": "global_afk_directive",
            "action": action,
            "user_email": Self.userEmailAddress,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// One email summarizing the flip, with a mailto: link per session. Each
    /// link's subject is pre-filled with a per-session AFK token marker so
    /// clicking it opens the mail client ready to reply to that specific
    /// session. Sessions still email organically when they have real
    /// questions/updates — this is the kickoff for the cases where Evan wants
    /// to initiate a conversation with one of them.
    ///
    /// Per-session tokens here are app-generated (a stable derivation from
    /// the sessionKey) rather than the per-session afk-skill-generated
    /// tokens. Reason: the skill's tokens are generated when each session
    /// enters AFK mode (i.e. AFTER they receive our directive), but the
    /// kickoff email is sent NOW. We could wait for tokens to flow back, but
    /// that was rejected as fragile in the design conversation. Using
    /// sessionKey-derived tokens means the mailto link works immediately and
    /// the EmailHandler can still route the reply by matching the token to
    /// the session.
    private func sendKickoffEmail(targets: [MCPSessionRegistry.SessionSnapshot]) async {
        guard !targets.isEmpty else {
            logger.info("global AFK kickoff email skipped — no targets")
            return
        }
        let provider = EmailProviderResolver().defaultProvider
        let timestamp = Date().formatted(date: .abbreviated, time: .shortened)

        // Enrich each session in parallel: tab name + cwd + Echo summary
        // (additive — Echo failure or timeout doesn't block the email).
        // CONCURRENCY CAP: llama-server runs with `--parallel 1` by default
        // (single slot, FIFO queue). Letting all N enrichments hit Echo at
        // once means N-1 of them sit queued past their per-call timeout and
        // get cancelled. Cap to 2 concurrent — gives the queue room to drain
        // while still parallelizing non-Echo work (tab lookup, cwd). Worst
        // case email send time = ceil(N/2) × echoTimeout.
        let echoConcurrencyCap = 2
        // Scan running Claude Code processes ONCE — recovers claudeSessionId
        // and cwd for sessions whose MCPSessionState never had identify()
        // called (the common case for ttys-bound sessions Sonata spawned via
        // bash). Without this, every such row in the email collapses to a
        // bare "interactive" label with no path.
        let procMap = Self.scanClaudeProcesses()
        let enriched: [EnrichedTarget] = await withTaskGroup(of: EnrichedTarget.self) { group in
            var inFlight = 0
            var pending = targets.makeIterator()
            // Prime the first cap-many tasks.
            for _ in 0..<echoConcurrencyCap {
                guard let snap = pending.next() else { break }
                group.addTask { await Self.enrich(snap: snap, procMap: procMap) }
                inFlight += 1
            }
            var out: [EnrichedTarget] = []
            for await item in group {
                out.append(item)
                inFlight -= 1
                if let next = pending.next() {
                    group.addTask { await Self.enrich(snap: next, procMap: procMap) }
                    inFlight += 1
                }
            }
            _ = inFlight
            // Preserve the input ordering so the email lines are stable.
            let order = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element.sessionKey, $0.offset) })
            out.sort { (order[$0.snap.sessionKey] ?? 0) < (order[$1.snap.sessionKey] ?? 0) }
            return out
        }

        // Split into two groups for the email so Sonata-owned tabs (which
        // Evan recognizes by name) are visually distinct from external
        // sessions (which need their Echo-derived handle to be findable).
        let ownedTabs = enriched.filter { $0.isOwnedTab }
        let externalSessions = enriched.filter { !$0.isOwnedTab }

        let ownedTextLines = ownedTabs.map { $0.plainLine(sonaInbox: Self.sonaInbox) }
        let externalTextLines = externalSessions.map { $0.plainLine(sonaInbox: Self.sonaInbox) }
        let ownedHtmlLines = ownedTabs.map { $0.htmlLine(sonaInbox: Self.sonaInbox) }
        let externalHtmlLines = externalSessions.map { $0.htmlLine(sonaInbox: Self.sonaInbox) }

        var textSections: [String] = []
        if !ownedTextLines.isEmpty {
            textSections.append("Sonata sessions:\n" + ownedTextLines.joined(separator: "\n"))
        }
        if !externalTextLines.isEmpty {
            textSections.append("Other sessions:\n" + externalTextLines.joined(separator: "\n"))
        }

        let textBody = """
        Global AFK is ON as of \(timestamp).

        \(targets.count) session(s) notified. They will route any questions to this email thread.

        To initiate a conversation with a specific session, click its mailto link below — the subject will be pre-filled with the right token. Sessions doing real work will also email you organically with their own threads.

        \(textSections.joined(separator: "\n\n"))

        Toggle AFK off in Sonata (title bar) or by replying to this email with the word "exit" on a line by itself (v2 — not yet wired).
        """

        var htmlSections: [String] = []
        if !ownedHtmlLines.isEmpty {
            htmlSections.append("<h4 style=\"margin:16px 0 4px 0;color:#444\">Sonata sessions</h4><ul style=\"padding-left:20px;margin-top:4px\">\(ownedHtmlLines.joined(separator: "\n"))</ul>")
        }
        if !externalHtmlLines.isEmpty {
            htmlSections.append("<h4 style=\"margin:16px 0 4px 0;color:#444\">Other sessions</h4><ul style=\"padding-left:20px;margin-top:4px\">\(externalHtmlLines.joined(separator: "\n"))</ul>")
        }

        let htmlBody = """
        <html><body style="font-family:-apple-system,sans-serif;line-height:1.5;color:#222">
        <p><strong>Global AFK is ON</strong> as of \(timestamp).</p>
        <p>\(targets.count) session(s) notified. They will route any questions to this email thread.</p>
        <p>To initiate a conversation with a specific session, click its link below — the subject will be pre-filled with the right token. Sessions doing real work will also email you organically with their own threads.</p>
        \(htmlSections.joined(separator: ""))
        <p style="color:#888;font-size:12px">Toggle AFK off in Sonata (title bar) or by replying to this email with the word "exit" on a line by itself (v2 — not yet wired).</p>
        </body></html>
        """

        do {
            try await provider.sendHTML(
                inbox: Self.sonaInbox,
                to: [Self.userEmailAddress],
                subject: "Sonata Global AFK on — \(targets.count) session(s) notified",
                text: textBody,
                html: htmlBody
            )
            logger.info("global AFK kickoff email sent to \(Self.userEmailAddress)")
        } catch {
            logger.error("global AFK kickoff email send failed: \(error)")
        }
    }
}

// MARK: - Session enrichment for the kickoff email

/// One row's worth of context for the kickoff email. Built in parallel by
/// `GlobalAFKOrchestrator.enrich` so a slow Echo summary on one session
/// doesn't block the others. All optional fields fall back gracefully.
struct EnrichedTarget {
    let snap: MCPSessionRegistry.SessionSnapshot
    /// User-facing identifier. For Sonata tabs: the tab name. For external
    /// sessions: an Echo-generated ≤4-word handle ("Auth Bug Debugging"),
    /// or the role label as ultimate fallback. Never empty.
    let displayName: String
    /// Working dir of the session. May be nil for external sessions that
    /// haven't called sonata_identify.
    let cwd: String?
    /// Unused in the current line shape — displayName now carries the
    /// disambiguating signal. Kept for future use (e.g. hover tooltip).
    let summary: String?
    /// True when this came from a Sonata-owned InteractiveSessionTab. Used
    /// to group sessions in the kickoff email's two-section layout.
    let isOwnedTab: Bool

    var token: String { "global-\(snap.sessionKey.prefix(8))" }

    func subject() -> String {
        "[AFK:\(token)] \(displayName)"
    }

    func mailto(sonaInbox: String) -> String {
        let encoded = subject().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject()
        return "mailto:\(sonaInbox)?subject=\(encoded)"
    }

    func plainLine(sonaInbox: String) -> String {
        var parts = ["- \(displayName)"]
        if let cwd { parts.append("· \(abbreviate(cwd))") }
        parts.append("→ \(mailto(sonaInbox: sonaInbox))")
        return parts.joined(separator: " ")
    }

    func htmlLine(sonaInbox: String) -> String {
        var parts = ["<strong>\(htmlEscape(displayName))</strong>"]
        if let cwd { parts.append("<code style=\"color:#888;font-size:12px\">\(htmlEscape(abbreviate(cwd)))</code>") }
        let link = "<a href=\"\(htmlEscape(mailto(sonaInbox: sonaInbox)))\">reply to this session</a>"
        return "<li>\(parts.joined(separator: " · ")) · \(link)</li>"
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension GlobalAFKOrchestrator {
    /// Build an EnrichedTarget for one session.
    ///
    /// Behavior splits on whether this is a Sonata-owned tab or an external
    /// session, because the needs differ:
    ///
    /// * **Sonata-owned tab** — we already have a meaningful display name
    ///   (the tab's title) and cwd. Skip the LLM call entirely; Echo would
    ///   add noise without disambiguating anything Evan can already see.
    /// * **External session** (any session with no tab match, including
    ///   paired Claude Code on another machine and the supervisor) — the
    ///   sessionKey IS the Claude session UUID for these, so we can locate
    ///   the transcript without sonata_identify. Ask Echo to invent a
    ///   ≤4-word handle ("Auth Bug Debugging") that becomes the displayName
    ///   — that's the actual disambiguator when multiple "interactive"
    ///   sessions are in the list.
    static func enrich(
        snap: MCPSessionRegistry.SessionSnapshot,
        procMap: [String: ClaudeProcInfo] = [:]
    ) async -> EnrichedTarget {
        let lookup = await tabLookup(for: snap)
        if let tabName = lookup.tabName {
            // Sonata-owned: name + cwd are enough. No Echo call.
            return EnrichedTarget(
                snap: snap,
                displayName: tabName,
                cwd: lookup.cwd,
                summary: nil,
                isOwnedTab: true
            )
        }
        // External: derive the displayName from Echo. claudeSessionId
        // resolution order:
        //   1. snapshot.claudeSessionId (from sonata_identify, if called)
        //   2. snapshot.sessionKey itself when it's a UUID (paired Claude
        //      Code uses its own session UUID as the MCP bearer)
        //   3. supervisor special-case: the supervisor's sessionKey is the
        //      literal string "supervisor" — fall back to finding the
        //      most-recently-modified jsonl in its known project dir
        //   4. process-scan fallback: walk running `claude` processes whose
        //      argv carries `--mcp-config session-<sessionKey>.json` and
        //      pull `--resume <uuid>` + cwd from there. Covers ttys-bound
        //      sessions Sonata spawned via bash that never called identify().
        let procInfo = procMap[snap.sessionKey]
        let cwd = snap.cwd ?? procInfo?.cwd ?? defaultCwdForRole(snap.role)
        let claudeSessionId: String?
        if let id = snap.claudeSessionId {
            claudeSessionId = id
        } else if isUUID(snap.sessionKey) {
            claudeSessionId = snap.sessionKey
        } else if snap.role == .supervisor {
            claudeSessionId = mostRecentTranscriptId(forProjectDir: "-Users-evan--sonata-supervisor")
        } else if let pid = procInfo?.claudeSessionId {
            claudeSessionId = pid
        } else {
            claudeSessionId = nil
        }
        let echoName = await echoSessionName(for: snap, claudeSessionId: claudeSessionId, cwd: cwd)
        return EnrichedTarget(
            snap: snap,
            displayName: echoName ?? snap.role.label,
            cwd: cwd,
            summary: nil,
            isOwnedTab: false
        )
    }

    /// One running `claude` process's contribution to the proc-scan map.
    /// claudeSessionId is the `--resume <uuid>` argv value when present;
    /// cwd comes from `lsof -p $PID -a -d cwd`. Either field may be nil.
    struct ClaudeProcInfo: Sendable {
        let pid: Int
        let claudeSessionId: String?
        let cwd: String?
    }

    /// Walk running processes once, build sessionKey → ClaudeProcInfo.
    /// Used as a fallback in `enrich` when MCPSessionState has no
    /// claudeSessionId/cwd because the session never called sonata_identify
    /// (the typical case for ttys-bound sessions spawned by Sonata's bash
    /// integration). The map key is the sessionKey extracted from the
    /// `--mcp-config /Users/evan/.sonata/mcp-cfg/session-<hex>.json` path.
    static func scanClaudeProcesses() -> [String: ClaudeProcInfo] {
        guard let psOutput = runShell(["/bin/ps", "-axww", "-o", "pid=,args="]) else {
            return [:]
        }
        var map: [String: ClaudeProcInfo] = [:]
        for rawLine in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Cheap pre-filter; argv has to mention claude AND the mcp-cfg
            // path, otherwise we can't extract a sessionKey anyway.
            guard line.contains("/claude") || line.contains(" claude ") else { continue }
            guard line.contains("session-") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let pidStr = parts.first, let pid = Int(pidStr) else { continue }
            let argv = String(line.dropFirst(pidStr.count).drop(while: { $0 == " " }))
            let sessionKey = extractSessionKeyFromArgv(argv)
            let claudeSessionId = extractResumeUUIDFromArgv(argv)
            guard let sk = sessionKey else { continue }
            let cwd = cwdForPid(pid)
            map[sk] = ClaudeProcInfo(pid: pid, claudeSessionId: claudeSessionId, cwd: cwd)
        }
        return map
    }

    /// Find `--mcp-config <path>` and pull the `session-<hex>` token from the
    /// basename. nil when the argv doesn't carry a recognizable Sonata mcp
    /// config (e.g. paired Claude Code on another box that loads a non-Sonata
    /// MCP, or a session spawned with no MCP config at all).
    private static func extractSessionKeyFromArgv(_ argv: String) -> String? {
        guard let r = argv.range(of: "--mcp-config ") else { return nil }
        let after = argv[r.upperBound...]
        let pathToken = String(after.split(separator: " ", maxSplits: 1).first ?? "")
        guard let startRange = pathToken.range(of: "session-"),
              let endRange = pathToken.range(of: ".json", range: startRange.upperBound..<pathToken.endIndex)
        else { return nil }
        let key = String(pathToken[startRange.upperBound..<endRange.lowerBound])
        return key.isEmpty ? nil : key
    }

    /// Find `--resume <uuid>` in argv. nil when the flag is absent (fresh
    /// session) or the value isn't UUID-shaped (we'd rather fall through
    /// than hand Echo a transcript path that won't exist).
    private static func extractResumeUUIDFromArgv(_ argv: String) -> String? {
        guard let r = argv.range(of: "--resume ") else { return nil }
        let after = argv[r.upperBound...]
        let token = String(after.split(separator: " ", maxSplits: 1).first ?? "")
        return isUUID(token) ? token : nil
    }

    /// lsof in -Fn mode emits one record per opened path prefixed with `n`;
    /// for `-d cwd` there's exactly one such line per process. Returns nil
    /// when lsof fails (process gone, permission, etc.) — caller falls back
    /// to role-default cwd.
    private static func cwdForPid(_ pid: Int) -> String? {
        guard let out = runShell(["/usr/sbin/lsof", "-p", "\(pid)", "-a", "-d", "cwd", "-Fn"]) else {
            return nil
        }
        for line in out.split(separator: "\n") {
            if line.hasPrefix("n/") { return String(line.dropFirst()) }
        }
        return nil
    }

    /// Spawn-and-collect a short-lived command. Returns stdout as UTF-8 on
    /// success, nil on launch failure or non-UTF-8 output. Stderr is silently
    /// discarded — these are diagnostic helpers, not user-facing commands.
    private static func runShell(_ argv: [String]) -> String? {
        guard let first = argv.first else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: first)
        proc.arguments = Array(argv.dropFirst())
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Look up the matching InteractiveSessionTab. Returns the tab name only
    /// when a match exists; nil tabName indicates this is an external
    /// (non-Sonata-owned) session that needs Echo to pick a handle.
    @MainActor
    private static func tabLookup(for snap: MCPSessionRegistry.SessionSnapshot) async -> (tabName: String?, cwd: String?) {
        if snap.role == .interactive {
            if let tab = InteractiveSessionsViewModel.shared.tabs.first(where: { $0.mcpSessionKey == snap.sessionKey }) {
                return (tab.name, tab.cwd.path)
            }
        }
        return (nil, nil)
    }

    /// Read the tail of the session's Claude Code transcript, ask Echo for a
    /// ≤12-word summary. Nil on any failure (transcript missing, Echo cold,
    /// timeout) — the kickoff email never blocks waiting for this. Logs
    /// the failure reason at debug-level so we can diagnose when summaries
    /// don't appear in the email.
    /// Ask Echo for a ≤4-word handle naming what this session is working on
    /// (e.g. "Auth Bug Debugging"). Used as the displayName for external
    /// sessions so multiple "interactive" rows are distinguishable. Returns
    /// nil on any failure — the caller falls back to the role label.
    private static func echoSessionName(for snap: MCPSessionRegistry.SessionSnapshot, claudeSessionId: String?, cwd: String?) async -> String? {
        let log = Self.diagLogger
        guard let claudeSessionId = claudeSessionId else {
            log.info("echoSessionName skip session=\(snap.sessionKey.prefix(12)) reason=no_claude_session_id")
            return nil
        }
        guard let transcriptTail = readTranscriptTail(claudeSessionId: claudeSessionId, cwd: cwd, log: log) else {
            return nil
        }
        guard !transcriptTail.isEmpty else {
            log.info("echoSessionName skip session=\(snap.sessionKey.prefix(12)) reason=empty_transcript")
            return nil
        }
        return await withTimeout(seconds: 12.0) {
            do {
                let raw = try await ChatServerManager.shared.chatCompletion(
                    systemPrompt: "Pick a SHORT handle naming what this Claude Code session is currently doing. Max FOUR words, Title Case, no quotes, no preamble, no trailing period. Examples: 'Auth Bug Fix', 'Scout Pipeline Tuning', 'Wiki Refactor'.",
                    userContent: transcriptTail,
                    maxTokens: 20,
                    temperature: 0.3,
                    seed: 42,
                    jsonObject: false
                )
                // Clamp hard: strip quotes/punctuation and cap to 4 words.
                let cleaned = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:"))
                let words = cleaned.split(separator: " ", maxSplits: 8).map(String.init)
                let capped = words.prefix(4).joined(separator: " ")
                if capped.isEmpty {
                    log.info("echoSessionName skip session=\(snap.sessionKey.prefix(12)) reason=empty_completion")
                    return nil
                }
                log.info("echoSessionName got session=\(snap.sessionKey.prefix(12)) name='\(capped)'")
                return capped
            } catch {
                log.info("echoSessionName skip session=\(snap.sessionKey.prefix(12)) reason=chat_error=\(error)")
                return nil
            }
        }
    }

    /// Shared diagnostic logger for the enrichment path. info-level so the
    /// reasons surface in the standard Sonata log without needing debug mode.
    private static var diagLogger: Logging.Logger {
        var log = Logging.Logger(label: "sonata.globalafk.enrich")
        log.logLevel = .info
        return log
    }

    /// Heuristic — is this string a Claude Code session UUID?
    /// 36 chars, 8-4-4-4-12 hex with dashes.
    private static func isUUID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        return UUID(uuidString: s) != nil
    }

    /// Default cwd for sessions whose snapshot.cwd is nil, falling back to
    /// well-known role-specific working directories Sonata creates itself.
    private static func defaultCwdForRole(_ role: SessionRole) -> String? {
        switch role {
        case .supervisor: return NSHomeDirectory() + "/.sonata-supervisor"
        case .worker, .interactive: return nil
        }
    }

    /// Find the most-recently-modified `.jsonl` file in a Claude Code
    /// project directory and return its basename (without the extension)
    /// as a claudeSessionId. Used for the supervisor's transcript lookup
    /// where the MCP layer has no other handle on its session UUID.
    private static func mostRecentTranscriptId(forProjectDir dir: String) -> String? {
        let path = NSHomeDirectory() + "/.claude/projects/" + dir
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        let jsonls = files.filter { $0.hasSuffix(".jsonl") }
        var best: (name: String, mtime: Date)?
        for f in jsonls {
            let full = path + "/" + f
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime { best = (f, mtime) }
        }
        guard let name = best?.name else { return nil }
        return String(name.dropLast(".jsonl".count))
    }

    /// Pull the last ~4KB of the transcript and crudely flatten to "U: …\nA: …"
    /// for Echo's input. Claude Code transcripts are JSONL with message events;
    /// we extract just `role` + `content` to give Echo something coherent.
    ///
    /// Lookup strategy: prefer the cwd-derived project directory (cwd with `/`
    /// → `-`), which is how Claude Code names the directory. Fall back to
    /// scanning every project dir for the matching jsonl filename.
    private static func readTranscriptTail(claudeSessionId: String, cwd: String?, log: Logging.Logger) -> String? {
        let projectsRoot = NSHomeDirectory() + "/.claude/projects"
        var candidates: [String] = []
        if let cwd {
            // Claude Code's directory naming: replace `/` with `-` and prepend `-`.
            let mangled = "-" + cwd.replacingOccurrences(of: "/", with: "-")
            candidates.append("\(projectsRoot)/\(mangled)/\(claudeSessionId).jsonl")
        }
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) {
            for dir in dirs {
                candidates.append("\(projectsRoot)/\(dir)/\(claudeSessionId).jsonl")
            }
        }
        let path = candidates.first { FileManager.default.fileExists(atPath: $0) }
        guard let path else {
            log.info("transcript not found session=\(claudeSessionId.prefix(12)) tried=\(candidates.count) cwd=\(cwd ?? "nil")")
            return nil
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readSize: UInt64 = 4096
        let offset = fileSize > readSize ? fileSize - readSize : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let lines = raw.split(separator: "\n").suffix(20)
        var out: [String] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            // Claude Code transcript shape: {"type":"user"|"assistant", "message":{"content":...}}
            let role = obj["type"] as? String ?? ""
            guard role == "user" || role == "assistant" else { continue }
            let message = obj["message"] as? [String: Any] ?? [:]
            let contentRaw = message["content"]
            let text: String
            if let s = contentRaw as? String {
                text = s
            } else if let arr = contentRaw as? [[String: Any]] {
                // Content blocks come in several shapes. Pull whichever
                // textual signal each block carries so the summary has
                // SOMETHING to work with even for thinking/tool-heavy
                // turns (common on Opus-class models that think before
                // every tool call):
                //   - {type:text, text:"…"}
                //   - {type:thinking, thinking:"…"}
                //   - {type:tool_use, name:"X", input:{…}}
                //   - {type:tool_result, content:"…" | [{type:text, …}]}
                text = arr.compactMap { block -> String? in
                    if let s = block["text"] as? String { return s }
                    if let s = block["thinking"] as? String { return s }
                    if let name = block["name"] as? String { return "[\(name)]" }
                    if let s = block["content"] as? String { return s }
                    if let arr = block["content"] as? [[String: Any]] {
                        return arr.compactMap { $0["text"] as? String }.joined(separator: " ")
                    }
                    return nil
                }.joined(separator: " ")
            } else {
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let prefix = role == "user" ? "U" : "A"
            out.append("\(prefix): \(String(trimmed.prefix(400)))")
        }
        return out.suffix(8).joined(separator: "\n")
    }

    /// Race a closure against a deadline. Returns the closure's result on
    /// completion, nil on timeout. The closure keeps running on timeout —
    /// no cancellation — which is fine for the LLM call (let it finish or
    /// die naturally; we just don't wait).
    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @Sendable @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }
}

private extension SessionRole {
    var label: String {
        switch self {
        case .worker: return "worker"
        case .interactive: return "interactive"
        case .supervisor: return "supervisor"
        }
    }
}
