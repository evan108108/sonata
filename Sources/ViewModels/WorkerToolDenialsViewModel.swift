import Foundation
import SwiftUI

// Backs the Settings → Workers → Tool Restrictions panel. Fetches the
// full set of tools available on /api/mcp/tools and the current deny
// rows from /api/worker/tool-denials, joins them client-side, and
// exposes toggle operations that hit /api/worker/tool-deny and
// /api/worker/tool-allow.

struct ToolDescriptor: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
}

struct ToolDenialEntry: Codable, Hashable {
    let toolName: String
    let appliesTo: String        // comma-separated roles
    let reason: String?
    let addedAt: Int64
    let addedBy: String?
}

@MainActor
class WorkerToolDenialsViewModel: ObservableObject {
    @Published var allTools: [ToolDescriptor] = []
    @Published var denials: [String: ToolDenialEntry] = [:]   // toolName → entry
    @Published var search: String = ""
    @Published var isLoading = false
    @Published var error: String?

    var filteredTools: [ToolDescriptor] {
        if search.isEmpty { return allTools }
        let q = search.lowercased()
        return allTools.filter {
            $0.name.lowercased().contains(q) ||
            $0.description.lowercased().contains(q)
        }
    }

    func isDenied(_ tool: String) -> Bool {
        denials[tool] != nil
    }

    func deniedRolesText(_ tool: String) -> String? {
        denials[tool]?.appliesTo
    }

    func fetchAll() async {
        isLoading = true
        defer { isLoading = false }
        async let toolsTask: () = fetchTools()
        async let denialsTask: () = fetchDenials()
        _ = await toolsTask
        _ = await denialsTask
    }

    private func fetchTools() async {
        do {
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/mcp/tools") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([ToolSchemaJSON].self, from: data)
            allTools = decoded
                .map { ToolDescriptor(name: $0.name, description: $0.description ?? "") }
                .sorted { $0.name < $1.name }
        } catch {
            self.error = "Tools fetch failed: \(error.localizedDescription)"
        }
    }

    private func fetchDenials() async {
        do {
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/worker/tool-denials") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([ToolDenialEntry].self, from: data)
            denials = Dictionary(uniqueKeysWithValues: decoded.map { ($0.toolName, $0) })
        } catch {
            self.error = "Denials fetch failed: \(error.localizedDescription)"
        }
    }

    /// Flip the deny state for a tool. When turning on, defaults to
    /// `appliesTo='worker'` (the common case — interactive sessions are
    /// you, the supervisor is internal). The panel doesn't expose
    /// per-role granularity in v0; that's a future UI affordance.
    func setDenied(tool: String, denied: Bool) async {
        // Optimistic local update
        if denied {
            denials[tool] = ToolDenialEntry(
                toolName: tool,
                appliesTo: "worker",
                reason: nil,
                addedAt: Int64(Date().timeIntervalSince1970 * 1000),
                addedBy: "user"
            )
        } else {
            denials.removeValue(forKey: tool)
        }
        do {
            let path = denied ? "/api/worker/tool-deny" : "/api/worker/tool-allow"
            guard let url = URL(string: "http://127.0.0.1:\(sonataPort)\(path)") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["toolName": tool]
            if denied { body["appliesTo"] = "worker" }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 300 {
                self.error = "Toggle failed (HTTP \(status))"
                await fetchDenials()  // resync
            }
        } catch {
            self.error = error.localizedDescription
            await fetchDenials()
        }
    }
}

private struct ToolSchemaJSON: Decodable {
    let name: String
    let description: String?
}
