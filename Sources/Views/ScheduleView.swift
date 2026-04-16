import SwiftUI

struct ScheduleView: View {
    @StateObject private var vm = ScheduleViewModel()
    @State private var showingCreateEvent = false
    @State private var showCompleted = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Schedule")
                    .font(.title.bold())
                Spacer()
                RefreshButton(isStale: vm.isStale) {
                    Task { await vm.fetch() }
                }

                Button {
                    showingCreateEvent = true
                } label: {
                    Label("New Event", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if let error = vm.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Cannot load schedule")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Calendar Events
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(.indigo)
                                Text("Calendar Events")
                                    .font(.headline)
                                let activeCount = vm.calendarEvents.filter { $0.enabled || $0.recurrence != nil }.count
                                let completedCount = vm.calendarEvents.count - activeCount
                                Text("(\(activeCount))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if completedCount > 0 {
                                    Button {
                                        showCompleted.toggle()
                                    } label: {
                                        Text(showCompleted ? "Hide completed (\(completedCount))" : "Show completed (\(completedCount))")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal)

                            let visibleEvents = showCompleted ? vm.calendarEvents : vm.calendarEvents.filter { $0.enabled || $0.recurrence != nil }
                            if visibleEvents.isEmpty {
                                Text("No calendar events")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            } else {
                                ForEach(visibleEvents) { event in
                                    CalendarEventRowView(
                                        event: event,
                                        onToggle: { Task { await vm.toggleCalendarEvent(event) } },
                                        onRunNow: { Task { await vm.runCalendarEvent(event) } },
                                        onDelete: { Task { await vm.deleteCalendarEvent(event) } },
                                        isRunning: vm.runningCalendarIds.contains(event._id)
                                    )
                                }
                            }
                        }

                        Divider()
                            .padding(.horizontal)

                        // Cron Jobs
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "clock.arrow.2.circlepath")
                                    .foregroundStyle(.purple)
                                Text("Cron Jobs")
                                    .font(.headline)
                                Text("(\(vm.cronJobs.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)

                            if vm.cronJobs.isEmpty {
                                Text("No cron jobs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            } else {
                                ForEach(vm.cronJobs) { job in
                                    CronJobRow(
                                        job: job,
                                        onTrigger: { Task { await vm.triggerCronJob(job) } },
                                        onDelete: { Task { await vm.deleteCronJob(job) } },
                                        isRunning: vm.runningCronNames.contains(job.name)
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .task {
            await vm.fetch()
            vm.startMonitoring()
        }
        .onAppear { Task { await vm.fetch() } }
        .sheet(isPresented: $showingCreateEvent) {
            CreateCalendarEventSheet { await vm.fetch() }
        }
    }

}

// MARK: - Calendar Event Row

private struct CalendarEventRowView: View {
    let event: CalendarEvent
    let onToggle: () -> Void
    var onRunNow: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var isRunning: Bool = false
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(event.enabled ? .green : .gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                        Text(event.nextFireString)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let recurrence = event.recurrence {
                        HStack(spacing: 3) {
                            Image(systemName: "repeat")
                            Text(recurrence)
                        }
                        .font(.caption)
                        .foregroundStyle(.purple)
                    }

                    if let lastStatus = event.lastRunStatus {
                        ScheduleStatusBadge(status: lastStatus)
                    }
                }
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .help("Running...")
                ScheduleStatusBadge(status: "running")
            } else {
                if let onRunNow = onRunNow {
                    Button { onRunNow() } label: {
                        Image(systemName: "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)
                    .help("Run now")
                }

                if onDelete != nil {
                    Button { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("Delete")
                }

                Toggle("", isOn: Binding(
                    get: { event.enabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .contextMenu {
            if let onRunNow = onRunNow {
                Button("Run Now") { onRunNow() }
            }
            Button(event.enabled ? "Disable" : "Enable") { onToggle() }
            Divider()
            if let onDelete = onDelete {
                Button("Delete", role: .destructive) { onDelete() }
            }
        }
        .alert("Delete \"\(event.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete?() }
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// MARK: - Cron Job Row

private struct CronJobRow: View {
    let job: CronJob
    let onTrigger: () -> Void
    var onDelete: (() -> Void)? = nil
    var isRunning: Bool = false
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(job.enabled ? .green : .gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                        Text(job.schedule)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let nextRun = job.nextRunAt {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text(relativeTimeString(ms: nextRun))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let exitCode = job.lastExitCode {
                        ScheduleStatusBadge(status: exitCode == 0 ? "success" : "failed")
                    }
                }
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .help("Running...")
                ScheduleStatusBadge(status: "running")
            } else {
                Button { onTrigger() } label: {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .help("Trigger now")

                if onDelete != nil {
                    Button { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("Delete")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .contextMenu {
            Button("Trigger Now") { onTrigger() }
            Divider()
            if let onDelete = onDelete {
                Button("Delete", role: .destructive) { onDelete() }
            }
        }
        .alert("Delete \"\(job.name)\"?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete?() }
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// MARK: - Status Badge

private struct ScheduleStatusBadge: View {
    let status: String

    var color: Color {
        switch status.lowercased() {
        case "success": return .green
        case "failed", "error": return .red
        case "running": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        Text(status)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Create Calendar Event Sheet

private struct CreateCalendarEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var recurrence = ""
    @State private var taskType = "claude"
    @State private var scheduledDate = Date().addingTimeInterval(3600)
    let onCreated: () async -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Calendar Event")
                .font(.headline)

            Form {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)

                DatePicker("Scheduled At", selection: $scheduledDate)

                TextField("Recurrence (e.g. daily, 30m, 2h)", text: $recurrence)
                    .textFieldStyle(.roundedBorder)

                Picker("Task Type", selection: $taskType) {
                    Text("Claude").tag("claude")
                    Text("Shell").tag("shell")
                    Text("HTTP").tag("http")
                }

                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    Task {
                        await createEvent()
                        dismiss()
                        await onCreated()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
        }
        .padding()
        .frame(width: 500, height: 420)
    }

    private func createEvent() async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/calendar/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "title": title,
            "scheduledAt": Int64(scheduledDate.timeIntervalSince1970 * 1000),
            "taskType": taskType,
        ]
        if !prompt.isEmpty { payload["prompt"] = prompt }
        if !recurrence.isEmpty { payload["recurrence"] = recurrence }

        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            request.httpBody = data
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}

// MARK: - Helpers

private func relativeTimeString(ms: Double) -> String {
    let nowMs = Date().timeIntervalSince1970 * 1000
    let diffSeconds = (ms - nowMs) / 1000
    if diffSeconds < 0 {
        let ago = -diffSeconds
        if ago < 60 { return "just now" }
        if ago < 3600 { return "\(Int(ago / 60))m ago" }
        if ago < 86400 { return "\(Int(ago / 3600))h ago" }
        return "\(Int(ago / 86400))d ago"
    }
    if diffSeconds < 60 { return "in <1m" }
    if diffSeconds < 3600 { return "in \(Int(diffSeconds / 60))m" }
    if diffSeconds < 86400 { return "in \(Int(diffSeconds / 3600))h" }
    return "in \(Int(diffSeconds / 86400))d"
}

// MARK: - Models

struct CalendarEvent: Identifiable, Decodable {
    let _id: String
    let title: String
    let description: String?
    let prompt: String?
    let scheduledAt: Int64
    let recurrence: String?
    let lastRunAt: Int64?
    let lastRunStatus: String?
    let runCount: Int
    let enabled: Bool
    let taskType: String

    var id: String { _id }

    var nextFireString: String {
        // Disabled one-shot that ran successfully = completed
        if !enabled && recurrence == nil && lastRunStatus == "success" {
            return "completed"
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let diffSeconds = (Double(scheduledAt) - nowMs) / 1000
        if diffSeconds < 0 {
            let ago = -diffSeconds
            if ago < 60 { return "overdue (just now)" }
            if ago < 3600 { return "overdue (\(Int(ago / 60))m)" }
            if ago < 86400 { return "overdue (\(Int(ago / 3600))h)" }
            return "overdue (\(Int(ago / 86400))d)"
        }
        if diffSeconds < 60 { return "in <1m" }
        if diffSeconds < 3600 { return "in \(Int(diffSeconds / 60))m" }
        if diffSeconds < 86400 { return "in \(Int(diffSeconds / 3600))h" }
        return "in \(Int(diffSeconds / 86400))d"
    }
}

struct CronJob: Identifiable, Decodable {
    let _id: String
    let name: String
    let schedule: String
    let command: String
    let enabled: Bool
    let lastRunAt: Double?
    let lastResult: String?
    let lastError: String?
    let lastExitCode: Double?
    let nextRunAt: Double?

    var id: String { _id }
}
