import Foundation
import SwiftUI

/// Snapshot of one row in the All-Sessions dashboard. Mirrors
/// MCPSessionRegistry.SessionSnapshot but on the main actor and with a
/// derived sub-type for type-chip rendering (the registry only stores
/// SessionRole, not the orchestrator/inspector/adhoc distinction inside
/// `interactive`).
struct AllSessionsRow: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case worker, supervisor, orchestrator, inspector, interactive

        var displayName: String {
            switch self {
            case .worker: return "worker"
            case .supervisor: return "supervisor"
            case .orchestrator: return "orchestrator"
            case .inspector: return "inspector"
            case .interactive: return "adhoc"
            }
        }

        var tint: Color {
            switch self {
            case .worker: return .cyan
            case .supervisor: return .indigo
            case .orchestrator: return .orange
            case .inspector: return .purple
            case .interactive: return .gray
            }
        }
    }

    let sessionKey: String
    let kind: Kind
    let lastContactedAt: Int64
    let hasSSE: Bool
    let inFlightEventId: String?

    var id: String { sessionKey }

    /// Alive = SSE attached AND we've heard from it in the last 90s. The
    /// session sweeper evicts much later than that, so this is a tighter
    /// "is the row meaningful right now" check.
    var isAlive: Bool {
        guard hasSSE else { return false }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return (nowMs - lastContactedAt) < 90_000
    }

    var lastContactedRelative: String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, nowMs - lastContactedAt) / 1000
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

    func fetch() async {
        guard let reg = MCPSessionRegistry.shared else {
            self.rows = []
            self.hasLoadedOnce = true
            return
        }
        let snaps = await reg.snapshot()
        // Sort: live first, then by sessionKey for stable ordering.
        let mapped = snaps
            .map { snap -> AllSessionsRow in
                AllSessionsRow(
                    sessionKey: snap.sessionKey,
                    kind: classify(sessionKey: snap.sessionKey, role: snap.role),
                    lastContactedAt: snap.lastContactedAt,
                    hasSSE: snap.hasSSE,
                    inFlightEventId: snap.inFlightEventId
                )
            }
            .sorted { lhs, rhs in
                if lhs.isAlive != rhs.isAlive { return lhs.isAlive }
                return lhs.sessionKey < rhs.sessionKey
            }
        self.rows = mapped
        self.hasLoadedOnce = true
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

    private func classify(sessionKey: String, role: SessionRole) -> AllSessionsRow.Kind {
        switch role {
        case .worker: return .worker
        case .supervisor: return .supervisor
        case .interactive:
            if sessionKey == "orchestrator" { return .orchestrator }
            if sessionKey.hasPrefix("inspector-") { return .inspector }
            return .interactive
        }
    }
}
