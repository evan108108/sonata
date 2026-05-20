import SwiftUI
import Foundation

struct ContactItem: Identifiable, Hashable, Equatable {
    let id: String
    let name: String
    let email: String
    let type: String        // "human", "ai", "service"
    let role: String?
    let provider: String?
    let model: String?
    let systemPrompt: String?
    let notes: String?
    let lastContactAt: Date?
    let messageCount: Int
    let createdAt: Date
    let autoAllowEmail: Bool
    let blockEmail: Bool
    let peerKind: String?

    static func == (lhs: ContactItem, rhs: ContactItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
class ContactViewModel: ObservableObject {
    @Published var contacts: [ContactItem] = []
    @Published var error: String?
    @Published var isLoading = false
    @Published var filterType: String? = nil
    @Published var searchQuery: String = ""

    var filteredContacts: [ContactItem] {
        var result = contacts
        if let type = filterType {
            result = result.filter { $0.type == type }
        }
        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                $0.email.lowercased().contains(q) ||
                ($0.notes?.lowercased().contains(q) ?? false)
            }
        }
        return result
    }

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/contacts?limit=500") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([ContactJSON].self, from: data)
            contacts = decoded.map { c in
                ContactItem(
                    id: c._id,
                    name: c.name,
                    email: c.email,
                    type: c.type,
                    role: c.role,
                    provider: c.provider,
                    model: c.model,
                    systemPrompt: c.systemPrompt,
                    notes: c.notes,
                    lastContactAt: c.lastContactAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    messageCount: c.messageCount,
                    createdAt: Date(timeIntervalSince1970: Double(c.createdAt) / 1000),
                    autoAllowEmail: (c.autoAllowEmail ?? 0) != 0,
                    blockEmail: (c.blockEmail ?? 0) != 0,
                    peerKind: c.peerKind
                )
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func upsert(
        name: String,
        email: String,
        type: String,
        role: String?,
        provider: String?,
        model: String?,
        systemPrompt: String?,
        notes: String?,
        peerKind: String? = nil,
        peerEndpoint: String? = nil,
        peerPubkey: String? = nil
    ) async -> Bool {
        var body: [String: Any] = [
            "name": name,
            "email": email,
            "type": type,
        ]
        if let r = role, !r.isEmpty { body["role"] = r }
        if let p = provider, !p.isEmpty { body["provider"] = p }
        if let m = model, !m.isEmpty { body["model"] = m }
        if let s = systemPrompt, !s.isEmpty { body["systemPrompt"] = s }
        if let n = notes, !n.isEmpty { body["notes"] = n }
        if let pk = peerKind, !pk.isEmpty { body["peerKind"] = pk }
        if let pe = peerEndpoint, !pe.isEmpty { body["peerEndpoint"] = pe }
        if let pp = peerPubkey, !pp.isEmpty { body["peerPubkey"] = pp }

        do {
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/contact") else { return false }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status < 300 {
                await fetch()
                return true
            }
            self.error = "Upsert failed (HTTP \(status))"
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Flip the inbound-email approval flag on a contact by email. Optimistically
    /// updates the local row so the UI reflects the new value immediately; the
    /// backend persists via `contact_set_email_flags`.
    func setEmailApproval(email: String, approved: Bool) async {
        // Optimistic local update
        if let idx = contacts.firstIndex(where: { $0.email.lowercased() == email.lowercased() }) {
            let c = contacts[idx]
            contacts[idx] = ContactItem(
                id: c.id, name: c.name, email: c.email, type: c.type,
                role: c.role, provider: c.provider, model: c.model,
                systemPrompt: c.systemPrompt, notes: c.notes,
                lastContactAt: c.lastContactAt, messageCount: c.messageCount,
                createdAt: c.createdAt,
                autoAllowEmail: approved,
                blockEmail: approved ? false : c.blockEmail,
                peerKind: c.peerKind
            )
        }
        do {
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/contact/email-flags") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = [
                "email": email,
                "autoAllowEmail": approved ? 1 : 0,
            ]
            if approved {
                // Approving clears any prior block.
                body["blockEmail"] = 0
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 300 {
                self.error = "Toggle failed (HTTP \(status)); refetching"
                await fetch()
            }
        } catch {
            self.error = error.localizedDescription
            await fetch()
        }
    }

    func delete(id: String) async {
        do {
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/contact?id=\(id)") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            _ = try await URLSession.shared.data(for: req)
            await fetch()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ContactJSON: Decodable {
    let _id: String
    let name: String
    let email: String
    let type: String
    let role: String?
    let provider: String?
    let model: String?
    let systemPrompt: String?
    let notes: String?
    let lastContactAt: Int64?
    let messageCount: Int
    let createdAt: Int64
    let autoAllowEmail: Int?
    let blockEmail: Int?
    let peerKind: String?
}
