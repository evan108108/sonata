import Foundation
import GRDB
import SwiftUI

/// Snapshot of one row in the All-Sessions dashboard. Each row is one
/// claude session — either DB-known and cross-checked live via
/// MCPConnections.hasLive (Workers / Connected) or visible only via
/// ~/.claude/sessions/ (Unconnected — a live claude process not
/// currently speaking MCP to Sonata).
struct AllSessionsRow: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case worker, supervisor, interactive

        var displayName: String {
            switch self {
            case .worker: return "worker"
            case .supervisor: return "supervisor"
            case .interactive: return "interactive"
            }
        }

        var tint: Color {
            switch self {
            case .worker: return .cyan
            case .supervisor: return .indigo
            case .interactive: return .gray
            }
        }
    }

    enum Section: String, Sendable {
        case workers, connected, unconnected
    }

    /// The routing identifier used for DMs / channel pushes. For
    /// MCP-attached sessions this is the bearer/sessionKey. For
    /// unconnected sessions (no MCP) this is claude's own session id
    /// — useful as a display id but not addressable until they
    /// connect.
    let sessionKey: String

    /// Claude's internal session id, set by the `sonata_identify` tool
    /// call (or read from `~/.claude/sessions/<pid>.json` for the
    /// unconnected section). May equal sessionKey for sona-launched
    /// sessions.
    let claudeSessionId: String?

    let kind: Kind
    let section: Section
    let cwd: String?
    let pid: Int?
    let hasSSE: Bool
    let inFlightEventId: String?

    /// Epoch ms of last contact. For MCP-attached sessions this is the
    /// registry's lastContactedAt; for unconnected, it's the file's
    /// updatedAt.
    let lastSeenMs: Int64

    /// First substantive user message in the transcript (skipping
    /// `<system-reminder>` wraps + post-compaction continuation blobs).
    /// Nil if the transcript can't be located or has no qualifying message.
    let firstPrompt: String?

    /// Most recent substantive user message in the transcript. Same
    /// filter as firstPrompt.
    let lastPrompt: String?

    /// Human-readable name when known (e.g. "Session 1", "My Session"
    /// for Interactive Sessions tabs that the user has named). Nil for
    /// external/sona-launched sessions where Sonata has no tab name.
    let displayName: String?

    var id: String { sessionKey }

    var lastSeenRelative: String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, nowMs - lastSeenMs) / 1000
        if delta < 5 { return "just now" }
        if delta < 60 { return "\(delta)s ago" }
        let m = delta / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        return "\(h / 24)d ago"
    }
}

@MainActor
final class AllSessionsViewModel: ObservableObject {
    @Published private(set) var rows: [AllSessionsRow] = []
    @Published private(set) var hasLoadedOnce = false
    @Published var dmResult: String?

    var workers: [AllSessionsRow] { rows.filter { $0.section == .workers } }
    var connected: [AllSessionsRow] { rows.filter { $0.section == .connected } }
    var unconnected: [AllSessionsRow] { rows.filter { $0.section == .unconnected } }

    struct WebviewGroup: Identifiable {
        let id: String                 // ownerAgentId (or "—" for user-created)
        let ownerLabel: String
        let tabs: [InteractiveSessionTab]
    }

    /// Webview sessions grouped by owning agent, for the Agent Webviews tree.
    /// Reads the live tabs directly (the view model's tab list is the source of truth);
    /// SwiftUI re-renders because InteractiveSessionsViewModel is observed.
    var webviewGroups: [WebviewGroup] {
        let webs = InteractiveSessionsViewModel.shared.tabs.filter { $0.kind == .webview }
        let byOwner = Dictionary(grouping: webs) { $0.ownerAgentId ?? "—" }
        return byOwner
            .map { WebviewGroup(id: $0.key, ownerLabel: $0.key == "—" ? "Unowned (user)" : $0.key, tabs: $0.value) }
            .sorted { $0.ownerLabel < $1.ownerLabel }
    }

    func fetch() async {
        var collected: [AllSessionsRow] = []

        // Build {sessionId: name} from Interactive Session tabs so we can
        // label sessions like "Sonata Default" / "My Session" in the
        // dashboard instead of just showing the bare sessionKey.
        //
        // Keyed by sessionId (the raw UUID) rather than mcpSessionKey
        // because sona-launched sessions register with the MCP transport
        // using bearer = SONA_SESSION_ID = sessionId, not the prefixed
        // mcpSessionKey form. The in-proc-MCP path uses mcpSessionKey, but
        // it's opt-in (flag-gated) and not the default for the in-rail
        // Sessions tab — so the dict key has to match what actually
        // registers.
        let interactiveSessionNames: [String: String] = Dictionary(
            uniqueKeysWithValues: InteractiveSessionsViewModel.shared.tabs.flatMap {
                // Index under BOTH so we cover the (rare) in-proc-MCP case
                // too — if mcpSessionKey happens to be the real registered
                // key for a given tab, the lookup still resolves.
                [($0.sessionId, $0.name), ($0.mcpSessionKey, $0.name)]
            }
        )

        // 1. Pre-scan ~/.claude/sessions/<pid>.json so we can look up
        // each live claude's pid + cwd + kind by its claude session id.
        // Used by BOTH the registry pass (to populate cwd/pid on Connected
        // rows whose sessionKey == claude session id, i.e. sona-launched)
        // AND the Unconnected pass (rows backed only by the filesystem).
        struct ClaudeProcessInfo {
            let pid: Int
            let cwd: String?
            let kindRaw: String
            let updatedAt: Int64
        }
        var byClaudeSessionId: [String: ClaudeProcessInfo] = [:]
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path) {
            for entry in entries where entry.hasSuffix(".json") {
                guard let pid = Int(String(entry.dropLast(".json".count))) else { continue }
                guard kill(pid_t(pid), 0) == 0 else { continue }
                guard let data = try? Data(contentsOf: sessionsDir.appendingPathComponent(entry)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sid = json["sessionId"] as? String
                else { continue }
                let updatedAt = (json["updatedAt"] as? Int64)
                    ?? (json["updatedAt"] as? Double).map { Int64($0) }
                    ?? (json["startedAt"] as? Int64)
                    ?? 0
                byClaudeSessionId[sid] = ClaudeProcessInfo(
                    pid: pid,
                    cwd: json["cwd"] as? String,
                    kindRaw: (json["kind"] as? String) ?? "interactive",
                    updatedAt: updatedAt
                )
            }
        }

        // 2. DB-known entities, cross-checked against live SSE connections
        // (MCPConnections.hasLive). Replaces the old registry snapshot.
        // attachedIds collects sessionId / claudeSessionId / derived key so
        // the Unconnected pass can dedup either way.
        var attachedIds: Set<String> = []
        let dbPool = SonataApp.sharedDbPool

        let workerRows: [Row] = (try? dbPool?.read { db in
            try Row.fetchAll(db, sql: "SELECT workerId, sessionLabel, currentEventId, lastHeartbeat FROM workers WHERE status != 'offline'")
        }).flatMap { $0 } ?? []
        for row in workerRows {
            guard let wid: String = row["workerId"] else { continue }
            let currentEventId: String? = row["currentEventId"]
            let lastHeartbeat: Int64 = row["lastHeartbeat"] ?? 0
            let label: String? = row["sessionLabel"]
            collected.append(AllSessionsRow(
                sessionKey: wid,
                claudeSessionId: wid,
                kind: .worker,
                section: .workers,
                cwd: nil,
                pid: nil,
                hasSSE: await MCPConnections.shared.hasLive(wid),
                inFlightEventId: (currentEventId?.isEmpty ?? true) ? nil : currentEventId,
                lastSeenMs: lastHeartbeat,
                firstPrompt: nil,
                lastPrompt: nil,
                displayName: label
            ))
            attachedIds.insert(wid)
        }

        let sessionRows: [Row] = (try? dbPool?.read { db in
            try Row.fetchAll(db, sql: "SELECT sessionId, name, cwd, claudeSessionId, lastActivityAt FROM interactiveSessions WHERE status = 'live'")
        }).flatMap { $0 } ?? []
        for row in sessionRows {
            guard let sid: String = row["sessionId"] else { continue }
            let ckey: String = row["claudeSessionId"] ?? sid
            let key = "session-" + sid.replacingOccurrences(of: "-", with: "").prefix(16)
            let proc = byClaudeSessionId[ckey]
            let rowCwd: String? = row["cwd"]
            let cwd = (rowCwd?.isEmpty ?? true) ? proc?.cwd : rowCwd
            let (first, last) = Self.transcriptPrompts(sessionId: ckey, cwd: cwd)
            let lastActivityAt: Int64? = row["lastActivityAt"]
            let name: String? = row["name"]
            collected.append(AllSessionsRow(
                sessionKey: key,
                claudeSessionId: ckey,
                kind: .interactive,
                section: .connected,
                cwd: cwd,
                pid: proc?.pid,
                hasSSE: await MCPConnections.shared.hasLive(key),
                inFlightEventId: nil,
                lastSeenMs: proc?.updatedAt ?? lastActivityAt ?? 0,
                firstPrompt: first,
                lastPrompt: last,
                displayName: name
            ))
            attachedIds.insert(sid)
            attachedIds.insert(ckey)
            attachedIds.insert(key)
        }

        if await MCPConnections.shared.hasLive("supervisor") {
            collected.append(AllSessionsRow(
                sessionKey: "supervisor",
                claudeSessionId: "supervisor",
                kind: .supervisor,
                section: .workers,
                cwd: nil,
                pid: nil,
                hasSSE: true,
                inFlightEventId: nil,
                lastSeenMs: Int64(Date().timeIntervalSince1970 * 1000),
                firstPrompt: nil,
                lastPrompt: nil,
                displayName: "supervisor"
            ))
        }

        // 3. Unconnected: live claude processes NOT in the registry.
        // Filtered: Sonata-internal processes (cwd under ~/.sonata/) are
        // hidden — they belong in the Workers section.
        let sonataInternalPrefix = "\(NSHomeDirectory())/.sonata/"
        for (sid, proc) in byClaudeSessionId {
            if attachedIds.contains(sid) { continue }
            // Sonata-owned tabs register under the derived "session-<hex16>"
            // key and rarely call sonata_identify, so the registry never
            // learns their full claude UUID — without this check every
            // connected tab shows up a second time as Unconnected.
            if attachedIds.contains(InteractiveSessionTab.mcpSessionKey(forClaudeSessionId: sid)) { continue }
            if let cwd = proc.cwd, cwd.hasPrefix(sonataInternalPrefix) { continue }
            let kind: AllSessionsRow.Kind
            switch proc.kindRaw.lowercased() {
            case "worker": kind = .worker
            case "supervisor": kind = .supervisor
            default: kind = .interactive
            }
            let (first, last) = Self.transcriptPrompts(sessionId: sid, cwd: proc.cwd)
            collected.append(AllSessionsRow(
                sessionKey: sid,
                claudeSessionId: sid,
                kind: kind,
                section: .unconnected,
                cwd: proc.cwd,
                pid: proc.pid,
                hasSSE: false,
                inFlightEventId: nil,
                lastSeenMs: proc.updatedAt,
                firstPrompt: first,
                lastPrompt: last,
                displayName: interactiveSessionNames[sid]
            ))
        }

        // Sort within each section: workers by sessionKey, others by recency.
        self.rows = collected.sorted { lhs, rhs in
            if lhs.section != rhs.section {
                return sectionOrder(lhs.section) < sectionOrder(rhs.section)
            }
            return lhs.lastSeenMs > rhs.lastSeenMs
        }
        self.hasLoadedOnce = true
    }

    private func sectionOrder(_ s: AllSessionsRow.Section) -> Int {
        switch s {
        case .workers: return 0
        case .connected: return 1
        case .unconnected: return 2
        }
    }

    /// Returns (firstPrompt, lastPrompt) by reading the head + tail of
    /// the session's transcript .jsonl. Both nil if the file can't be
    /// located or has no qualifying user message.
    /// Transcript path: ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
    /// where encoded-cwd has `/` and `.` replaced with `-`.
    static func transcriptPrompts(sessionId: String, cwd: String?)
        -> (first: String?, last: String?) {
        guard let cwd = cwd else { return (nil, nil) }
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let path = "\(NSHomeDirectory())/.claude/projects/\(encoded)/\(sessionId).jsonl"
        guard let fh = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? fh.close() }

        let fileSize: Int = {
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        }()
        guard fileSize > 0 else { return (nil, nil) }

        // Head: first 16 KiB for the first prompt.
        let headBytes = min(16 * 1024, fileSize)
        let headData: Data = (try? fh.read(upToCount: headBytes)) ?? Data()
        let first = headData
            .split(separator: 0x0a /* newline */)
            .lazy
            .compactMap { Self.extractUserPrompt(fromLine: Data($0)) }
            .first

        // Tail: last 128 KiB for the most recent prompt. Scan reversed.
        let tailBytes = min(128 * 1024, fileSize)
        let tailOffset = UInt64(fileSize - tailBytes)
        try? fh.seek(toOffset: tailOffset)
        let tailData: Data = (try? fh.read(upToCount: tailBytes)) ?? Data()
        let last = tailData
            .split(separator: 0x0a)
            .reversed()
            .lazy
            .compactMap { Self.extractUserPrompt(fromLine: Data($0)) }
            .first

        return (first, last)
    }

    /// Parse one .jsonl line; return the prompt text if it's a
    /// substantive user message. Filters out tool results, channel
    /// pushes, system-reminder wrappers, post-compaction continuation
    /// blobs, and local-command echoes.
    private static func extractUserPrompt(fromLine line: Data) -> String? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "user",
              let msg = obj["message"] as? [String: Any]
        else { return nil }

        // content can be:
        //   - String (typical user-typed prompt)
        //   - Array of blocks (image-bearing prompts have a "text"
        //     block alongside an "image" block; tool_result messages
        //     have only "tool_result" blocks)
        var text: String?
        if let s = msg["content"] as? String {
            text = s
        } else if let arr = msg["content"] as? [[String: Any]] {
            // Pick the first text block; tool_result-only arrays
            // return nil because no text block matches.
            for block in arr where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String, !t.isEmpty {
                    text = t
                    break
                }
            }
        }

        guard let t = text, !t.isEmpty else { return nil }
        // Filter known non-prompt wrappers — user-typed prompts never
        // start with any of these.
        let nonPromptPrefixes = [
            "<system-reminder>",
            "<local-command-caveat>",
            "<local-command-stdout>",
            "<command-name>",
            "<command-message>",
            "<command-args>",
            "<channel source=",
            "This session is being continued",
        ]
        for prefix in nonPromptPrefixes {
            if t.hasPrefix(prefix) { return nil }
        }
        return t
    }

    /// Send a DM via `/api/dm/send`. fromSessionId is "dashboard" so
    /// recipients can tell the message originated from this UI rather than
    /// another agent.
    func sendDM(target: String, body: String) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/dm/send")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "target": target,
            "fromSessionId": "dashboard",
            "body": body,
            "context": "dashboard-manual",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = obj["status"] as? String {
                let reason = obj["reason"] as? String
                let suffix = reason.map { " (\($0))" } ?? ""
                self.dmResult = "Sent to \(target) — \(status)\(suffix)"
            } else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                self.dmResult = "Failed (HTTP \(code)) — \(snippet)"
            }
        } catch {
            self.dmResult = "Failed — \(error.localizedDescription)"
        }
    }

    /// Broadcast a DM via `/api/dm/broadcast`.
    /// Filter: "all" | "workers" | "sessions" | "supervisor" | "peers"
    /// (also accepts the legacy "interactive"/"humans" aliases).
    func broadcast(filter: String, body: String) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/dm/broadcast")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "fromSessionId": "dashboard",
            "body": body,
            "filter": filter,
            "context": "dashboard-broadcast",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sent = obj["sent"] as? Int {
                let notLive = obj["not_live"] as? Int ?? 0
                let notFound = obj["not_found"] as? Int ?? 0
                let total = obj["total"] as? Int ?? sent
                var summary = "Broadcast \(filter): \(sent)/\(total) sent"
                if notLive > 0 { summary += ", \(notLive) not live" }
                if notFound > 0 { summary += ", \(notFound) not found" }
                self.dmResult = summary
            } else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                self.dmResult = "Broadcast failed (HTTP \(code)) — \(snippet)"
            }
        } catch {
            self.dmResult = "Broadcast failed — \(error.localizedDescription)"
        }
    }
}
