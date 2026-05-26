import SwiftUI
import Foundation

struct EmailInboxItem: Identifiable, Hashable, Equatable {
    let id: String
    let address: String
    let role: String        // "sona", "scoutleader", "relay", "custom"
    let displayName: String?
    let enabled: Bool
    let autoReply: Bool
    let dispatchTo: String?
    let systemPrompt: String?
    let provider: String
    let providerConfig: String?
    let createdAt: Date
    let updatedAt: Date

    static func == (lhs: EmailInboxItem, rhs: EmailInboxItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
class EmailConfigViewModel: ObservableObject {
    @Published var inboxes: [EmailInboxItem] = []
    @Published var error: String?
    @Published var isLoading = false

    private var baseURL: String { "http://127.0.0.1:\(sonataPort)" }

    // MARK: - Fetch

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let url = URL(string: "\(baseURL)/api/email/inboxes") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([InboxJSON].self, from: data)
            inboxes = decoded.map { c in
                EmailInboxItem(
                    id: c._id,
                    address: c.address,
                    role: c.role,
                    displayName: c.displayName,
                    enabled: c.enabled,
                    autoReply: c.autoReply,
                    dispatchTo: c.dispatchTo,
                    systemPrompt: c.systemPrompt,
                    provider: c.provider ?? "agentmail",
                    providerConfig: c.providerConfig,
                    createdAt: Date(timeIntervalSince1970: Double(c.createdAt) / 1000),
                    updatedAt: Date(timeIntervalSince1970: Double(c.updatedAt) / 1000)
                )
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Upsert

    func upsert(
        address: String,
        role: String,
        displayName: String?,
        enabled: Bool,
        autoReply: Bool,
        dispatchTo: String?,
        systemPrompt: String?,
        provider: String = "agentmail",
        imapHost: String? = nil,
        smtpHost: String? = nil,
        imapPort: Int? = nil,
        smtpPort: Int? = nil,
        imapPassword: String? = nil
    ) async -> Bool {
        var body: [String: Any] = [
            "address": address,
            "role": role,
            "enabled": enabled,
            "autoReply": autoReply,
            "provider": provider,
        ]
        if let d = displayName, !d.isEmpty { body["displayName"] = d }
        if let t = dispatchTo, !t.isEmpty { body["dispatchTo"] = t }
        if let s = systemPrompt, !s.isEmpty { body["systemPrompt"] = s }
        if provider == "imap" {
            if let h = imapHost { body["imapHost"] = h }
            if let h = smtpHost { body["smtpHost"] = h }
            if let p = imapPort { body["imapPort"] = p }
            if let p = smtpPort { body["smtpPort"] = p }
            if let pw = imapPassword, !pw.isEmpty { body["imapPassword"] = pw }
        }

        return await post(path: "/api/email/inbox", body: body)
    }

    // MARK: - Delete

    func delete(id: String) async -> Bool {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/api/email/inbox?id=\(encoded)") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status < 300 {
                await fetch()
                return true
            }
            self.error = "Delete failed: HTTP \(status)"
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Toggle

    func setEnabled(id: String, enabled: Bool) async -> Bool {
        let path = enabled ? "/api/email/inbox/enable" : "/api/email/inbox/disable"
        return await post(path: path, body: ["id": id])
    }

    // MARK: - Private

    private func post(path: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(baseURL)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status < 300 {
                await fetch()
                return true
            }
            self.error = "Request failed: HTTP \(status)"
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

// MARK: - JSON Decoding

private struct InboxJSON: Decodable {
    let _id: String
    let address: String
    let role: String
    let displayName: String?
    let enabled: Bool
    let autoReply: Bool
    let dispatchTo: String?
    let systemPrompt: String?
    let provider: String?
    let providerConfig: String?
    let createdAt: Int64
    let updatedAt: Int64
}
