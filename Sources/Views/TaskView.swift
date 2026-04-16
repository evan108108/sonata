import SwiftUI

struct TaskView: View {
    @StateObject private var vm = TaskViewModel()
    @State private var selectedTask: TaskItem?
    @State private var showingCreateSheet = false
    @State private var filterStatus: String? = nil

    private let statusOrder = ["active", "pending", "failed", "completed", "cancelled"]

    var groupedTasks: [(String, [TaskItem])] {
        let filtered = filterStatus == nil ? vm.tasks : vm.tasks.filter { $0.status == filterStatus }
        var groups: [String: [TaskItem]] = [:]
        for task in filtered {
            groups[task.status, default: []].append(task)
        }
        return statusOrder.compactMap { status in
            guard let items = groups[status], !items.isEmpty else { return nil }
            return (status, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tasks")
                    .font(.title.bold())
                Spacer()

                // Filter picker
                Picker("Filter", selection: Binding(
                    get: { filterStatus ?? "all" },
                    set: { filterStatus = $0 == "all" ? nil : $0 }
                )) {
                    Text("All").tag("all")
                    Text("Active").tag("active")
                    Text("Pending").tag("pending")
                    Text("Failed").tag("failed")
                    Text("Completed").tag("completed")
                    Text("Cancelled").tag("cancelled")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)

                RefreshButton(isStale: vm.isStale) {
                    Task { await vm.fetch() }
                }

                Button {
                    showingCreateSheet = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            // Stats bar
            if let stats = vm.stats {
                HStack(spacing: 24) {
                    StatPill(label: "Active", count: stats.active, color: .blue)
                    StatPill(label: "Pending", count: stats.pending, color: .orange)
                    StatPill(label: "Failed", count: stats.failed, color: .red)
                    StatPill(label: "Completed", count: stats.completed, color: .green)
                    StatPill(label: "Cancelled", count: stats.cancelled, color: .gray)
                    Spacer()
                    Text("\(stats.total) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            if let error = vm.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Cannot load tasks")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.tasks.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading tasks...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Task list
                    List(selection: $selectedTask) {
                        ForEach(groupedTasks, id: \.0) { status, items in
                            Section {
                                ForEach(items) { task in
                                    TaskRowView(task: task)
                                        .tag(task)
                                }
                            } header: {
                                HStack {
                                    TaskStatusBadge(status: status)
                                    Text("(\(items.count))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 350)

                    // Detail pane
                    if let task = selectedTask {
                        TaskDetailView(task: task, onAction: { await vm.fetch() })
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "checklist")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Select a task to view details")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task {
            await vm.fetch()
            vm.startMonitoring()
        }
        .onAppear { Task { await vm.fetch() } }
        .onDisappear { vm.stopMonitoring() }
        .sheet(isPresented: $showingCreateSheet) {
            CreateTaskSheet { await vm.fetch() }
        }
    }
}

// MARK: - Task Row

private struct TaskRowView: View {
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
                if task.status == "active",
                   let startedAt = task.startedAt,
                   (Date().timeIntervalSince1970 * 1000 - Double(startedAt)) > 1_800_000 {
                    Text("stuck?")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.15), in: Capsule())
                        .foregroundStyle(.yellow)
                }
                Spacer()
                TaskStatusBadge(status: task.status)
            }
            HStack(spacing: 8) {
                TaskPriorityBadge(priority: task.priority)
                if let project = task.project {
                    Text(project)
                        .font(.caption)
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Text(task.ageString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Task Detail

private struct TaskDetailView: View {
    let task: TaskItem
    let onAction: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title + status
                HStack {
                    Text(task.title)
                        .font(.title2.bold())
                    Spacer()
                    TaskStatusBadge(status: task.status)
                }

                // Metadata grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    DetailField(label: "Priority", value: task.priority)
                    DetailField(label: "Project", value: task.project ?? "—")
                    DetailField(label: "Assigned To", value: task.assignedTo ?? "—")
                    DetailField(label: "Created", value: task.createdDateString)
                    DetailField(label: "Source", value: task.source)
                    DetailField(label: "Retry Count", value: "\(task.retryCount)")
                }

                if !task.blockedBy.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blocked By")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(task.blockedBy, id: \.self) { id in
                            Text(id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let parentTask = task.parentTask {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Parent Task")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(parentTask)
                            .font(.caption.monospaced())
                    }
                }

                if let prompt = task.prompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(prompt)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let result = task.result, !result.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(result)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let lastError = task.lastError, !lastError.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Error")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        Text(lastError)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Divider()

                // Action buttons
                HStack(spacing: 12) {
                    if task.status == "pending" || task.status == "active" {
                        Button {
                            Task {
                                await postAction("complete", id: task._id)
                                await onAction()
                            }
                        } label: {
                            Label("Complete", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }

                    if task.status == "pending" || task.status == "active" {
                        Button {
                            Task {
                                await postAction("fail", id: task._id)
                                await onAction()
                            }
                        } label: {
                            Label("Fail", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                    if task.status == "pending" || task.status == "active" {
                        Button {
                            Task {
                                await postAction("cancel", id: task._id)
                                await onAction()
                            }
                        } label: {
                            Label("Cancel", systemImage: "minus.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                    }

                    if task.status == "failed" || task.status == "cancelled" {
                        Button {
                            Task {
                                await postAction("retry", id: task._id)
                                await onAction()
                            }
                        } label: {
                            Label("Retry", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 400)
    }

    private func postAction(_ action: String, id: String) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/\(action)?id=\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - Create Task Sheet

private struct CreateTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var priority = "normal"
    @State private var project = ""
    @State private var assignedTo = ""
    let onCreated: () async -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Task")
                .font(.headline)

            Form {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)

                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )

                Picker("Priority", selection: $priority) {
                    Text("Critical").tag("critical")
                    Text("High").tag("high")
                    Text("Normal").tag("normal")
                    Text("Low").tag("low")
                    Text("Backlog").tag("backlog")
                }

                TextField("Project (optional)", text: $project)
                    .textFieldStyle(.roundedBorder)

                TextField("Assigned To (optional)", text: $assignedTo)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    Task {
                        await createTask()
                        dismiss()
                        await onCreated()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }

    private func createTask() async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/task/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "title": title,
            "source": "sonata-ui",
            "priority": priority,
        ]
        if !prompt.isEmpty { payload["prompt"] = prompt }
        if !project.isEmpty { payload["project"] = project }
        if !assignedTo.isEmpty { payload["assignedTo"] = assignedTo }

        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            request.httpBody = data
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}

// MARK: - Badges

struct TaskStatusBadge: View {
    let status: String

    var color: Color {
        switch status {
        case "active": return .blue
        case "pending": return .orange
        case "completed": return .green
        case "failed": return .red
        case "cancelled": return .gray
        default: return .secondary
        }
    }

    var body: some View {
        Text(status.capitalized)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct TaskPriorityBadge: View {
    let priority: String

    var icon: String {
        switch priority {
        case "critical": return "exclamationmark.3"
        case "high": return "exclamationmark.2"
        case "normal": return "minus"
        case "low": return "arrow.down"
        case "backlog": return "tray"
        default: return "minus"
        }
    }

    var color: Color {
        switch priority {
        case "critical": return .red
        case "high": return .orange
        case "normal": return .secondary
        case "low": return .blue
        case "backlog": return .gray
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
            Text(priority.capitalized)
        }
        .font(.caption2)
        .foregroundStyle(color)
    }
}

private struct StatPill: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count)")
                .font(.caption.bold().monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DetailField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
        }
    }
}

// MARK: - Models

struct TaskItem: Identifiable, Hashable, Decodable {
    let _id: String
    let _creationTime: Int64
    let title: String
    let description: String?
    let status: String
    let priority: String
    let prompt: String?
    let project: String?
    let blockedBy: [String]
    let parentTask: String?
    let source: String
    let result: String?
    let assignedTo: String?
    let retryCount: Int
    let lastError: String?
    let startedAt: Int64?
    let createdAt: Int64
    let updatedAt: Int64

    var id: String { _id }

    var ageString: String {
        let seconds = (Double(Date().timeIntervalSince1970 * 1000) - Double(createdAt)) / 1000
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    var createdDateString: String {
        let date = Date(timeIntervalSince1970: Double(createdAt) / 1000)
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(_id) }
    static func == (lhs: TaskItem, rhs: TaskItem) -> Bool { lhs._id == rhs._id }
}

struct TaskStats: Decodable {
    let pending: Int
    let active: Int
    let completed: Int
    let failed: Int
    let cancelled: Int
    let total: Int
}
