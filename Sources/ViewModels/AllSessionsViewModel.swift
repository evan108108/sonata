import Foundation
import SwiftUI

/// Snapshot of one row in the All-Sessions dashboard. Each row is one
/// claude session — either visible to Sonata via MCPSessionRegistry
/// (Workers / Connected) or visible only via ~/.claude/sessions/
/// (Unconnected — a live claude process not currently speaking MCP
/// to Sonata).
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

    func fetch() async {
        var collected: [AllSessionsRow] = []

        // 1. MCP-attached sessions from the registry.
        // attachedIds collects both sessionKey AND claudeSessionId so the
        // ~/.claude/sessions pass can dedup either way:
        //   - sona-launched: sessionKey == claude session uuid (bearer)
        //   - identified anon-XXX: claudeSessionId is the uuid (set via sonata_identify)
        //   - legacy workers/supervisor: sessionKey is workerId, no uuid match
        //     (handled by the cwd-prefix filter below)
        var attachedIds: Set<String> = []
        if let reg = MCPSessionRegistry.shared {
            let snaps = await reg.snapshot()
            for snap in snaps {
                let kind: AllSessionsRow.Kind
                let section: AllSessionsRow.Section
                switch snap.role {
                case .worker:
                    kind = .worker
                    section = .workers
                case .supervisor:
                    kind = .supervisor
                    section = .workers
                case .interactive:
                    kind = .interactive
                    section = .connected
                }
                collected.append(AllSessionsRow(
                    sessionKey: snap.sessionKey,
                    claudeSessionId: snap.claudeSessionId,
                    kind: kind,
                    section: section,
                    cwd: snap.cwd,
                    pid: snap.pid,
                    hasSSE: snap.hasSSE,
                    inFlightEventId: snap.inFlightEventId,
                    lastSeenMs: snap.lastContactedAt
                ))
                attachedIds.insert(snap.sessionKey)
                if let csid = snap.claudeSessionId {
                    attachedIds.insert(csid)
                }
            }
        }

        // 2. Live-but-unconnected claudes from ~/.claude/sessions/.
        // These are claude processes that Sonata can see via the
        // per-PID metadata files but that aren't currently MCP-attached
        // (typically: launched without `sona`, or before SONA_SESSION_ID
        // env wiring was in place).
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for entry in entries where entry.hasSuffix(".json") {
                guard let pid = Int(String(entry.dropLast(".json".count))) else { continue }
                // Only show live processes.
                guard kill(pid_t(pid), 0) == 0 else { continue }
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(entry)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let sessionId = json["sessionId"] as? String ?? entry
                // If this claude is already MCP-attached, skip — it shows up
                // in workers/connected via the registry pass.
                if attachedIds.contains(sessionId) { continue }
                // Sonata-internal processes (workers, supervisor) belong in
                // the Workers section and are surfaced via WorkerManager.
                // Filter them out of Unconnected by cwd prefix so they never
                // double-list as "external claudes."
                let cwdField = json["cwd"] as? String ?? ""
                if cwdField.hasPrefix("\(NSHomeDirectory())/.sonata/") { continue }
                let kindRaw = (json["kind"] as? String) ?? "interactive"
                let kind: AllSessionsRow.Kind
                switch kindRaw.lowercased() {
                case "worker": kind = .worker
                case "supervisor": kind = .supervisor
                default: kind = .interactive
                }
                let cwd = json["cwd"] as? String
                let updatedAt = (json["updatedAt"] as? Int64)
                    ?? (json["updatedAt"] as? Double).map { Int64($0) }
                    ?? (json["startedAt"] as? Int64)
                    ?? 0
                collected.append(AllSessionsRow(
                    sessionKey: sessionId,
                    claudeSessionId: sessionId,
                    kind: kind,
                    section: .unconnected,
                    cwd: cwd,
                    pid: pid,
                    hasSSE: false,
                    inFlightEventId: nil,
                    lastSeenMs: updatedAt
                ))
            }
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

    /// Send a DM via the existing `/api/dm/send` action. fromSessionId is
    /// "dashboard" so recipients can tell the message originated from this
    /// UI rather than another agent.
    func sendDM(target: String, body: String) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/dm/send")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "targetSessionId": target,
            "fromSessionId": "dashboard",
            "body": body,
            "context": "dashboard-manual",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let delivery = obj["deliveryStatus"] as? String {
                self.dmResult = "Sent to \(target) — \(delivery)"
            } else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                self.dmResult = "Failed (HTTP \(status)) — \(snippet)"
            }
        } catch {
            self.dmResult = "Failed — \(error.localizedDescription)"
        }
    }

    /// Broadcast a DM via `/api/dm/broadcast` (sonar_dm_broadcast).
    /// Filter: "all" | "workers" | "interactive" | "supervisor".
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
            let status = http?.statusCode ?? 0
            if status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let count = obj["delivered_count"] as? Int {
                self.dmResult = "Broadcast \(filter): delivered to \(count) session(s)"
            } else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                self.dmResult = "Broadcast failed (HTTP \(status)) — \(snippet)"
            }
        } catch {
            self.dmResult = "Broadcast failed — \(error.localizedDescription)"
        }
    }
}
