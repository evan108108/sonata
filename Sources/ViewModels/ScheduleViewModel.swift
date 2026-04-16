import SwiftUI
import Combine

@MainActor
class ScheduleViewModel: ObservableObject {
    @Published var calendarEvents: [CalendarEvent] = []
    @Published var cronJobs: [CronJob] = []
    @Published var error: String?
    @Published var isStale = false
    @Published var runningCalendarIds: Set<String> = []
    @Published var runningCronNames: Set<String> = []

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

            // Clear running state for completed events
            for event in self.calendarEvents where runningCalendarIds.contains(event._id) {
                if event.lastRunStatus == "success" || event.lastRunStatus == "error" {
                    if let lastRun = event.lastRunAt, lastRun > event.scheduledAt {
                        runningCalendarIds.remove(event._id)
                    }
                }
            }
            // Clear running cron jobs that have a fresh lastRunAt
            for job in self.cronJobs where runningCronNames.contains(job.name) {
                if let lastRun = job.lastRunAt, let nextRun = job.nextRunAt, lastRun < nextRun {
                    runningCronNames.remove(job.name)
                }
            }
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
        runningCronNames.insert(job.name)
        let encoded = job.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? job.name
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/cron/trigger?name=\(encoded)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await URLSession.shared.data(for: request)
        await fetch()
    }

    func runCalendarEvent(_ event: CalendarEvent) async {
        runningCalendarIds.insert(event._id)
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/calendar/trigger?id=\(event._id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await URLSession.shared.data(for: request)
        await fetch()
    }

    func deleteCalendarEvent(_ event: CalendarEvent) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/calendar?id=\(event._id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
        await fetch()
    }

    func deleteCronJob(_ job: CronJob) async {
        let encoded = job.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? job.name
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/cron?name=\(encoded)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
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
        guard let calURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/calendar/all"),
              let cronURL = URL(string: "http://127.0.0.1:\(sonataPort)/api/cron/list") else { return }
        guard let (calData, _) = try? await URLSession.shared.data(from: calURL),
              let (cronData, _) = try? await URLSession.shared.data(from: cronURL) else { return }
        let newHash = calData.hashValue ^ cronData.hashValue
        if lastDataHash != 0 && newHash != lastDataHash {
            await fetch()
        }
    }
}
