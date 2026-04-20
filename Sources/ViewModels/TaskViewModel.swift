import SwiftUI
import Combine

@MainActor
class TaskViewModel: ObservableObject {
    @Published var activeTasks: [TaskItem] = []      // active + pending — always all
    @Published var completedTasks: [TaskItem] = []   // completed/failed/cancelled — paginated
    @Published var stats: TaskStats?
    @Published var error: String?
    @Published var isStale = false
    @Published var hasMoreCompleted = false

    private var completedLimit = 20
    private var pollTimer: AnyCancellable?
    private var lastStatsHash: Int = 0

    var tasks: [TaskItem] { activeTasks + completedTasks }

    func fetch() async {
        do {
            let statsURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/stats")!
            let activeURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/list?limit=500&status=active")!
            let pendingURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/list?limit=500&status=pending")!
            // Fetch more than we need from each status, then trim the combined list
            let fetchLimit = completedLimit + 10  // overfetch slightly to fill the combined limit
            let doneURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/list?limit=\(fetchLimit)&status=completed")!
            let failedURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/list?limit=\(fetchLimit)&status=failed")!
            let cancelledURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/list?limit=\(fetchLimit)&status=cancelled")!

            async let sData = URLSession.shared.data(from: statsURL)
            async let activeData = URLSession.shared.data(from: activeURL)
            async let pendingData = URLSession.shared.data(from: pendingURL)
            async let doneData = URLSession.shared.data(from: doneURL)
            async let failedData = URLSession.shared.data(from: failedURL)
            async let cancelledData = URLSession.shared.data(from: cancelledURL)

            let decoder = JSONDecoder()

            let (s, _) = try await sData
            let stats = try decoder.decode(TaskStats.self, from: s)
            self.stats = stats
            self.lastStatsHash = s.hashValue

            let (a, _) = try await activeData
            let (p, _) = try await pendingData
            let active = try decoder.decode([TaskItem].self, from: a)
            let pending = try decoder.decode([TaskItem].self, from: p)
            self.activeTasks = pending + active  // pending first

            let (d, _) = try await doneData
            let (f, _) = try await failedData
            let (c, _) = try await cancelledData
            let done = try decoder.decode([TaskItem].self, from: d)
            let failed = try decoder.decode([TaskItem].self, from: f)
            let cancelled = try decoder.decode([TaskItem].self, from: c)
            // Combine all finished tasks, sort by most recent, then cap at the limit
            let allFinished = done + failed + cancelled
            self.completedTasks = Array(allFinished.sorted { $0.updatedAt > $1.updatedAt }.prefix(completedLimit))
            print("[DEBUG] TaskViewModel.fetch: done=\(done.count) failed=\(failed.count) cancelled=\(cancelled.count) allFinished=\(allFinished.count) capped=\(self.completedTasks.count) limit=\(completedLimit)")

            let totalFinished = stats.completed + stats.failed + stats.cancelled
            self.hasMoreCompleted = totalFinished > self.completedTasks.count

            self.error = nil
            self.isStale = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        completedLimit += 20
        await fetch()
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
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/stats") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        if lastStatsHash != 0 && data.hashValue != lastStatsHash {
            await fetch()
        }
    }
}
