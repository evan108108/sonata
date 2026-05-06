import Foundation
import SwiftUI

struct SupervisorMessage: Identifiable, Hashable {
    let id: String
    let role: String      // "user", "assistant", "system", "alert"
    let content: String
    let createdAt: Int64
}

@MainActor
final class SupervisorChatViewModel: ObservableObject {
    @Published var messages: [SupervisorMessage] = []
    @Published var inFlight: Bool = false
    @Published var lastError: String?
    @Published var lastActivityAt: Date?
    @Published var supervisorRunning: Bool = false

    private var refreshTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var isVisible: Bool = false

    private struct MessagesResponseItem: Decodable {
        let _id: String?
        let role: String?
        let content: String?
        let createdAt: Int64?
    }

    private struct StatusResponse: Decodable {
        let running: Bool?
        let unreadAlerts: Int?
        let lastActivity: Int64?
    }

    private struct QueryRequest: Encodable {
        let message: String
    }

    private struct QueryResponse: Decodable {
        let success: Bool?
        let messageId: String?
        let eventId: String?
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible {
            Task { await refresh() }
            Task { await refreshStatus() }
            startTimers()
        } else {
            stopTimers()
        }
    }

    private func startTimers() {
        stopTimers()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await self?.refreshStatus()
            }
        }
    }

    private func stopTimers() {
        refreshTask?.cancel()
        refreshTask = nil
        statusTask?.cancel()
        statusTask = nil
    }

    deinit {
        refreshTask?.cancel()
        statusTask?.cancel()
    }

    func refresh() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/supervisor/messages?limit=10")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoded = try JSONDecoder().decode([MessagesResponseItem].self, from: data)
            let mapped = decoded.compactMap { item -> SupervisorMessage? in
                guard let id = item._id, let role = item.role, let content = item.content else {
                    return nil
                }
                return SupervisorMessage(
                    id: id,
                    role: role,
                    content: content,
                    createdAt: item.createdAt ?? 0
                )
            }
            self.messages = mapped
            let timestamps = mapped.map { $0.createdAt }
            if let latest = timestamps.max(), latest > 0 {
                self.lastActivityAt = Date(timeIntervalSince1970: TimeInterval(latest) / 1000.0)
            }
        } catch {
            // Quiet failure — surface only on submit so the panel doesn't blink red on every poll
        }
    }

    func refreshStatus() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/supervisor/status")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
            self.supervisorRunning = decoded.running ?? false
            if let activity = decoded.lastActivity, activity > 0 {
                self.lastActivityAt = Date(timeIntervalSince1970: TimeInterval(activity) / 1000.0)
            }
        } catch {
            // ignore — status check is best-effort
        }
    }

    func submit(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let capped = String(trimmed.prefix(4000))

        inFlight = true
        lastError = nil
        defer { inFlight = false }

        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/supervisor/query")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(QueryRequest(message: capped))

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Couldn't reach supervisor — try again in a moment."
                return
            }
            _ = try? JSONDecoder().decode(QueryResponse.self, from: data)
            await refresh()
        } catch {
            lastError = "Couldn't reach supervisor — try again in a moment."
        }
    }
}

extension SupervisorChatViewModel {
    /// Compact "Xs/Xm/Xh/Xd ago" string. Returns nil if never seen.
    var lastActivityLabel: String? {
        guard let date = lastActivityAt else { return nil }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "active" }
        if secs < 3_600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3_600)h ago" }
        return "\(secs / 86_400)d ago"
    }
}
