import SwiftUI
import Combine

@MainActor
class TaskViewModel: ObservableObject {
    @Published var tasks: [TaskItem] = []
    @Published var stats: TaskStats?
    @Published var error: String?
    @Published var isStale = false

    private var pollTimer: AnyCancellable?
    private var lastDataHash: Int = 0

    func fetch() async {
        do {
            let statsURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/stats")!
            let listURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/list?limit=200")!
            async let statsData = URLSession.shared.data(from: statsURL)
            async let listData = URLSession.shared.data(from: listURL)
            let (sData, _) = try await statsData
            let (lData, _) = try await listData
            let decoder = JSONDecoder()
            self.stats = try decoder.decode(TaskStats.self, from: sData)
            self.tasks = try decoder.decode([TaskItem].self, from: lData)
            self.error = nil
            self.lastDataHash = lData.hashValue
            self.isStale = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func postAction(_ action: String, id: String) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/\(action)?id=\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await URLSession.shared.data(for: request)
        await fetch()
    }

    func startMonitoring() {
        pollTimer = Timer.publish(every: 3, on: .main, in: .common)
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
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/list?limit=200") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        if lastDataHash != 0 && data.hashValue != lastDataHash {
            await fetch()
        }
    }
}
