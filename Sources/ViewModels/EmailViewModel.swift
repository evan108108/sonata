import SwiftUI
import Combine

@MainActor
class EmailViewModel: ObservableObject {
    @Published var emails: [EmailItem] = []
    @Published var unreadCount: Int = 0
    @Published var error: String?
    @Published var isStale = false

    private var pollTimer: AnyCancellable?
    private var lastDataHash: Int = 0

    func fetch() async {
        do {
            let recentURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/email/recent?limit=100")!
            let checkURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/email/check")!
            async let recentData = URLSession.shared.data(from: recentURL)
            async let checkData = URLSession.shared.data(from: checkURL)
            let (rData, _) = try await recentData
            let (cData, _) = try await checkData
            let decoder = JSONDecoder()
            self.emails = try decoder.decode([EmailItem].self, from: rData)
            struct UnreadCheck: Decodable { let unread: Int }
            self.unreadCount = (try? decoder.decode(UnreadCheck.self, from: cData))?.unread ?? 0
            self.error = nil
            self.lastDataHash = rData.hashValue
            self.isStale = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markEmail(_ action: String, id: String) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/email/\(action)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let data = try? JSONSerialization.data(withJSONObject: ["id": id]) {
            request.httpBody = data
            _ = try? await URLSession.shared.data(for: request)
        }
        await fetch()
    }

    func startMonitoring() {
        pollTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.checkForChanges() }
            }
    }

    func stopMonitoring() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func checkForChanges() async {
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/email/recent?limit=100") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let newHash = data.hashValue
        if lastDataHash != 0 && newHash != lastDataHash {
            isStale = true
        }
    }
}
