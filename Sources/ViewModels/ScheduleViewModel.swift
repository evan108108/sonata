import SwiftUI
import Combine

@MainActor
class ScheduleViewModel: ObservableObject {
    @Published var calendarEvents: [CalendarEvent] = []
    @Published var cronJobs: [CronJob] = []
    @Published var error: String?
    @Published var isStale = false

    private var pollTimer: AnyCancellable?
    private var lastDataHash: Int = 0

    func fetch() async {
        do {
            let calURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/calendar/all")!
            let cronURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/cron/list")!
            async let calData = URLSession.shared.data(from: calURL)
            async let cronData = URLSession.shared.data(from: cronURL)
            let (cData, _) = try await calData
            let (jData, _) = try await cronData
            let decoder = JSONDecoder()
            self.calendarEvents = try decoder.decode([CalendarEvent].self, from: cData)
            self.cronJobs = try decoder.decode([CronJob].self, from: jData)
            self.error = nil
            self.lastDataHash = cData.hashValue ^ jData.hashValue
            self.isStale = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleCalendarEvent(_ event: CalendarEvent) async {
        let action = event.enabled ? "disable" : "enable"
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/calendar/\(action)?id=\(event._id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await URLSession.shared.data(for: request)
        await fetch()
    }

    func triggerCronJob(_ job: CronJob) async {
        let encoded = job.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? job.name
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/cron/trigger?name=\(encoded)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await URLSession.shared.data(for: request)
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
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/calendar/all") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        if lastDataHash != 0 && data.hashValue != lastDataHash {
            isStale = true
        }
    }
}
