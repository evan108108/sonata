import SwiftUI

// Native replacement for the former tasks.html webview. Mirrors that page's
// behavior: a status-grouped sidebar (with real totals from /api/task/stats and
// per-status "load more" paging) and a detail pane showing prompt / result /
// error, the worker attempts for the task, and the raw JSON. Data comes from the
// same local HTTP API the webview used.

// MARK: - Models

private struct TaskItem: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let assignedTo: String?
    let parentId: String?
    let prompt: String?
    let result: String?
    let error: String?
    let createdAt: Int64?
    let rawPretty: String

    var createdDate: Date? {
        createdAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    static func == (lhs: TaskItem, rhs: TaskItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Parse a bare JSON array of task objects. Manual (vs Codable) so the
    /// string-or-object `result` field and the raw-JSON dump both come for free.
    static func parse(_ data: Data?) -> [TaskItem] {
        guard let data,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict in
            guard let id = (dict["_id"] as? String) ?? (dict["id"] as? String) else { return nil }
            let resultStr: String? = {
                if let s = dict["result"] as? String { return s }
                if let obj = dict["result"], !(obj is NSNull),
                   let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                    return String(decoding: d, as: UTF8.self)
                }
                return nil
            }()
            let rawPretty = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return TaskItem(
                id: id,
                title: dict["title"] as? String ?? "(untitled)",
                status: (dict["status"] as? String ?? "unknown").lowercased(),
                assignedTo: dict["assignedTo"] as? String,
                parentId: dict["parentId"] as? String,
                prompt: dict["prompt"] as? String,
                result: resultStr,
                error: dict["error"] as? String,
                createdAt: (dict["createdAt"] as? NSNumber)?.int64Value,
                rawPretty: rawPretty
            )
        }
    }
}

private struct WorkerAttempt: Identifiable {
    let id: String
    let status: String
    let assignedTo: String?
    let sessionId: String?
    let assignedAt: Int64?
    let completedAt: Int64?

    var durationText: String? {
        guard let a = assignedAt, let c = completedAt, c > a else { return nil }
        return "\(Int((c - a) / 1000))s"
    }

    static func parse(_ data: Data?) -> [WorkerAttempt] {
        guard let data,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict in
            guard let id = (dict["_id"] as? String) ?? (dict["id"] as? String) else { return nil }
            return WorkerAttempt(
                id: id,
                status: (dict["status"] as? String ?? "unknown").lowercased(),
                assignedTo: dict["assignedTo"] as? String,
                sessionId: dict["sessionId"] as? String,
                assignedAt: (dict["assignedAt"] as? NSNumber)?.int64Value,
                completedAt: (dict["completedAt"] as? NSNumber)?.int64Value
            )
        }
    }
}

private struct TaskStats: Decodable {
    let active: Int
    let pending: Int
    let completed: Int
    let failed: Int
    let cancelled: Int
}

// Status display helpers — shared by list rows, section headers, and detail.
private let statusOrder = ["active", "in_progress", "pending", "completed", "done", "failed", "cancelled"]

private func statusColor(_ status: String) -> Color {
    switch status {
    case "active", "in_progress": return .green
    case "pending":               return .yellow
    case "completed", "done":     return .blue
    case "failed":                return .red
    case "cancelled":             return .purple
    default:                      return .secondary
    }
}

// MARK: - View

struct TasksView: View {
    @State private var tasks: [TaskItem] = []
    @State private var stats: TaskStats?
    @State private var filter = ""
    @State private var selectedId: String?
    @State private var isLoading = false
    @State private var error: String?

    // Per-status page size for the finished buckets (the active/pending buckets
    // are always fetched whole — they're small).
    @State private var limits: [String: Int] = ["completed": 20, "failed": 20, "cancelled": 20]

    private var selectedTask: TaskItem? {
        tasks.first { $0.id == selectedId }
    }

    private var filteredTasks: [TaskItem] {
        let f = filter.lowercased()
        guard !f.isEmpty else { return tasks }
        return tasks.filter { $0.title.lowercased().contains(f) || $0.status.contains(f) }
    }

    private var grouped: [String: [TaskItem]] {
        Dictionary(grouping: filteredTasks, by: \.status)
    }

    private var orderedStatuses: [String] {
        let g = grouped
        let known = statusOrder.filter { g[$0] != nil }
        let extra = g.keys.filter { !statusOrder.contains($0) }.sorted()
        return known + extra
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                listContent
                Divider()
                statsBar
            }
            .sonataSidebar()
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task)
                    .id(task.id)
            } else {
                ContentUnavailableView(
                    "Select a task to view details",
                    systemImage: "checklist"
                )
            }
        }
        .task { await loadTasks() }
    }

    // MARK: Sidebar pieces

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter tasks…", text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            Button {
                Task { await loadTasks() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(10)
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var listContent: some View {
        if isLoading && tasks.isEmpty {
            Spacer(); ProgressView(); Spacer()
        } else if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.red)
                Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if filteredTasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 36)).foregroundStyle(.secondary)
                Text(filter.isEmpty ? "No tasks" : "No matches").font(.headline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(orderedStatuses, id: \.self) { status in
                        HStack(spacing: 6) {
                            Text(status.uppercased())
                            Text(countLabel(status)).foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                        ForEach(grouped[status] ?? []) { task in
                            TaskListRow(task: task)
                                .sidebarRowSelection(selectedId == task.id)
                                .onTapGesture { selectedId = task.id }
                        }

                        if hasMore(status) {
                            Button {
                                Task { await loadMore(status) }
                            } label: {
                                Text("Load more \(status)…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
        }
    }

    private var statsBar: some View {
        HStack {
            if let s = stats {
                Label("\(s.active + s.pending) open", systemImage: "circle.dashed")
                Spacer()
                Label("\(s.completed) done", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: Counts / paging

    /// Real total for a status from /api/task/stats (nil if unknown).
    private func realCount(_ status: String) -> Int? {
        guard let s = stats else { return nil }
        switch status {
        case "active", "in_progress": return s.active
        case "pending":               return s.pending
        case "completed", "done":     return s.completed
        case "failed":                return s.failed
        case "cancelled":             return s.cancelled
        default:                      return nil
        }
    }

    private func countLabel(_ status: String) -> String {
        let shown = grouped[status]?.count ?? 0
        if let total = realCount(status), total != shown {
            return "(\(shown) of \(total))"
        }
        return "(\(shown))"
    }

    private func hasMore(_ status: String) -> Bool {
        guard limits[status] != nil, let total = realCount(status) else { return false }
        let shown = grouped[status]?.count ?? 0
        return total > shown
    }

    private func loadMore(_ status: String) async {
        if let cur = limits[status] { limits[status] = cur + 20 }
        await loadTasks()
    }

    // MARK: Networking

    private func loadTasks() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        async let statsData = fetchData("/api/task/stats")
        async let activeData = fetchData("/api/task/list?limit=500&status=active")
        async let pendingData = fetchData("/api/task/list?limit=500&status=pending")
        async let completedData = fetchData("/api/task/list?limit=\(limits["completed"] ?? 20)&status=completed")
        async let failedData = fetchData("/api/task/list?limit=\(limits["failed"] ?? 20)&status=failed")
        async let cancelledData = fetchData("/api/task/list?limit=\(limits["cancelled"] ?? 20)&status=cancelled")

        let (sD, aD, pD, cD, fD, xD) = await (statsData, activeData, pendingData, completedData, failedData, cancelledData)

        if let sD { stats = try? JSONDecoder().decode(TaskStats.self, from: sD) }

        let merged = TaskItem.parse(pD)
            + TaskItem.parse(aD)
            + TaskItem.parse(cD)
            + TaskItem.parse(fD)
            + TaskItem.parse(xD)

        if merged.isEmpty && sD == nil {
            error = "Couldn't reach the task API."
        }
        tasks = merged
    }

    private func fetchData(_ path: String) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)\(path)") else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }
}

// MARK: - Row

private struct TaskListRow: View {
    let task: TaskItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(statusColor(task.status))
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.body)
                    .lineLimit(2)
                if let when = task.createdDate {
                    Text(when.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct TaskDetailView: View {
    let task: TaskItem

    @State private var attempts: [WorkerAttempt] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(task.title)
                    .font(.title2.bold())
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    badge(task.status, color: statusColor(task.status))
                    if let who = task.assignedTo { badge("→ \(who)") }
                    if task.parentId != nil { badge("subtask", color: .purple) }
                    Spacer()
                    if let when = task.createdDate {
                        Text("created \(when.formatted(.dateTime))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }

                if let prompt = task.prompt, !prompt.isEmpty {
                    section("Prompt") { monospaced(prompt) }
                }
                if let result = task.result, !result.isEmpty {
                    section("Result") { monospaced(result) }
                }
                if let err = task.error, !err.isEmpty {
                    section("Error") { monospaced(err, color: .red) }
                }
                if !attempts.isEmpty {
                    section("Worker Attempts (\(attempts.count))") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(attempts) { AttemptRow(attempt: $0, taskTitle: task.title) }
                        }
                    }
                }
                section("Raw") {
                    monospaced(task.rawPretty, size: 10, color: .secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: task.id) {
            // Attempts only exist for tasks that reached a worker.
            guard task.status == "completed" || task.status == "failed" else {
                attempts = []
                return
            }
            await loadAttempts()
        }
    }

    private func loadAttempts() async {
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/worker/events/recent?limit=50&task_id=\(task.id)")
        else { return }
        let data = try? await URLSession.shared.data(from: url).0
        attempts = WorkerAttempt.parse(data)
    }

    // MARK: bits

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func monospaced(_ text: String, size: CGFloat = 12, color: Color = .primary) -> some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func badge(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.primary : color)
    }
}

private struct AttemptRow: View {
    let attempt: WorkerAttempt
    let taskTitle: String

    var body: some View {
        HStack(spacing: 8) {
            Text(attempt.status)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(statusColor(attempt.status).opacity(0.18), in: Capsule())
                .foregroundStyle(statusColor(attempt.status))
            if let who = attempt.assignedTo {
                Text(who).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let dur = attempt.durationText {
                Text(dur).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if attempt.status == "assigned" {
                Text("(in progress)").font(.caption).italic().foregroundStyle(.blue)
            } else if let sid = attempt.sessionId {
                Button("Resume") { Task { await resume(sid) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.purple)
            }
        }
    }

    private func resume(_ sessionId: String) async {
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/worker/inspect") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "title": taskTitle])
        _ = try? await URLSession.shared.data(for: req)
    }
}
