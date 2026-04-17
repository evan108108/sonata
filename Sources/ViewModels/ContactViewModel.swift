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
                    createdAt: Date(timeIntervalSince1970: Double(c.createdAt) / 1000)
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
        notes: String?
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
}
