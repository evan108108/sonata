import Foundation

@MainActor
final class WebviewSessionConfigViewModel: ObservableObject {
    @Published var idleSuspendSec: Int = 300
    @Published var hardCloseSec: Int = 1800
    @Published var maxLiveSessions: Int = 8
    @Published var isSaving = false
    @Published var error: String?

    private var baseURL: String { "http://127.0.0.1:\(sonataPort)" }

    private struct ConfigJSON: Decodable { let idleSuspendSec, hardCloseSec, maxLiveSessions: Int; let updatedAt: Int64 }

    func fetch() async {
        guard let url = URL(string: "\(baseURL)/api/webview/config") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let d = try JSONDecoder().decode(ConfigJSON.self, from: data)
            idleSuspendSec = d.idleSuspendSec; hardCloseSec = d.hardCloseSec; maxLiveSessions = d.maxLiveSessions; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func save() async -> Bool {
        isSaving = true; defer { isSaving = false }
        guard let url = URL(string: "\(baseURL)/api/webview/config") else { error = "bad url"; return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["idleSuspendSec": idleSuspendSec, "hardCloseSec": hardCloseSec, "maxLiveSessions": maxLiveSessions]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 300
            if !ok { error = "save failed" }; return ok
        } catch { self.error = error.localizedDescription; return false }
    }
}
