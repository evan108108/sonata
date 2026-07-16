import SwiftUI

// MARK: - Models

private struct MemoryItem: Identifiable, Decodable {
    let _id: String
    let _creationTime: Int64?
    let content: String
    let type: String
    let tags: [String]?
    let source: String?
    let importance: Double
    let l0: String?
    let l1: String?
    let accessCount: Int?
    let lastAccessedAt: Int64?
    let status: String?
    let supersededBy: String?
    let revisionOf: String?
    let revisionNote: String?
    let validFrom: Int64?
    let validUntil: Int64?
    let project: String?
    let topic: String?
    let createdAt: Int64
    let updatedAt: Int64

    var id: String { _id }

    var createdDate: Date {
        Date(timeIntervalSince1970: Double(createdAt) / 1000)
    }
    var updatedDate: Date {
        Date(timeIntervalSince1970: Double(updatedAt) / 1000)
    }
    var contentPreview: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 100 { return trimmed }
        return String(trimmed.prefix(100)) + "..."
    }
    var typeIcon: String {
        switch type {
        case "learning":             return "lightbulb.fill"
        case "observation":          return "eye.fill"
        case "decision":             return "arrow.triangle.branch"
        case "preference":           return "heart.fill"
        case "error_pattern":        return "exclamationmark.triangle.fill"
        case "code_pattern":         return "chevron.left.forwardslash.chevron.right"
        case "conversation_summary": return "bubble.left.and.bubble.right.fill"
        case "reflection":           return "sparkles"
        case "feeling":              return "face.smiling"
        case "fact":                 return "book.closed.fill"
        default:                     return "doc.text.fill"
        }
    }
    var typeColor: Color {
        switch type {
        case "learning":             return .yellow
        case "observation":          return .blue
        case "decision":             return .green
        case "preference":           return .pink
        case "error_pattern":        return .red
        case "code_pattern":         return .purple
        case "conversation_summary": return .cyan
        case "reflection":           return .indigo
        case "feeling":              return .orange
        case "fact":                 return .mint
        default:                     return .secondary
        }
    }
    var importanceColor: Color {
        if importance >= 8 { return .red }
        if importance >= 6 { return .orange }
        if importance >= 4 { return .yellow }
        return .secondary
    }
}

private struct MemoryStatsResponse: Decodable {
    let totalMemories: Int
    let avgImportance: Double
    let byType: [String: Int]?
    let entityCount: Int?
    let relationCount: Int?
}

// MARK: - View

struct MemoryView: View {
    @State private var searchText = ""
    @State private var memories: [MemoryItem] = []
    @State private var selectedMemory: MemoryItem?
    @State private var isLoading = false
    @State private var error: String?

    // Filters
    @State private var typeFilter: String = "all"
    @State private var minImportance: Double = 0
    @State private var projectFilter: String = ""

    // Date-range filter (post-2026-07-16). Both bounds are optional. Toggling
    // `dateRangeActive` reveals two DatePickers; server-side maps them to the
    // `after`/`before` params on /api/memory/search + /recent.
    @State private var dateRangeActive: Bool = false
    @State private var afterDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var beforeDate: Date = .now

    // Stats
    @State private var totalCount: Int = 0
    @State private var avgImportance: Double = 0

    // Debounce
    @State private var searchTask: Task<Void, Never>?

    private let memoryTypes = [
        "all", "learning", "observation", "decision", "preference",
        "error_pattern", "code_pattern", "conversation_summary",
        "reflection", "feeling", "fact"
    ]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search memories...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onChange(of: searchText) { _, newValue in
                            debouncedSearch(newValue)
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            Task { await fetchRecent() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.top)

                // Filter controls — kept compact so they fit the sidebar width.
                HStack(spacing: 10) {
                    Picker("Type", selection: $typeFilter) {
                        ForEach(memoryTypes, id: \.self) { t in
                            Text(t == "all" ? "All Types" : t.replacingOccurrences(of: "_", with: " ").capitalized)
                                .tag(t)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: typeFilter) { _, _ in
                        triggerSearch()
                    }

                    Spacer(minLength: 0)

                    // Date-range toggle. Off by default so the row stays clean;
                    // clicking reveals two compact DatePickers below the row.
                    Button {
                        dateRangeActive.toggle()
                        triggerSearch()
                    } label: {
                        Image(systemName: dateRangeActive ? "calendar.badge.checkmark" : "calendar")
                            .foregroundStyle(dateRangeActive ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Filter by createdAt date range")

                    HStack(spacing: 4) {
                        Text("Min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(minImportance))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 14)
                        Slider(value: $minImportance, in: 0...10, step: 1)
                            .frame(width: 90)
                            .onChange(of: minImportance) { _, _ in
                                triggerSearch()
                            }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // Date-range pickers appear only when active. Compact styling
                // so the sidebar width still fits; `graphical` would be too big.
                if dateRangeActive {
                    HStack(spacing: 8) {
                        Text("From").font(.caption).foregroundStyle(.secondary)
                        DatePicker("", selection: $afterDate, displayedComponents: .date)
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: afterDate) { _, _ in triggerSearch() }

                        Text("to").font(.caption).foregroundStyle(.secondary)
                        DatePicker("", selection: $beforeDate, displayedComponents: .date)
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: beforeDate) { _, _ in triggerSearch() }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)
                }

                Divider()
                    .padding(.top, 8)

                // Results list
                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if memories.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "No memories yet" : "No results")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(memories) { mem in
                                MemoryListRow(memory: mem)
                                    .sidebarRowSelection(selectedMemory?.id == mem.id)
                                    .onTapGesture { selectedMemory = mem }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                }

                // Stats bar
                Divider()
                HStack {
                    Label("\(totalCount) memories", systemImage: "number")
                    Spacer()
                    Label(String(format: "Avg importance: %.1f", avgImportance), systemImage: "chart.bar.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .sonataSidebar()
        } detail: {
            if let mem = selectedMemory {
                MemoryDetailView(memory: mem)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a memory to view details")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await fetchRecent()
            await fetchStats()
        }
    }

    // MARK: - Networking

    private func debouncedSearch(_ query: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if query.isEmpty {
                await fetchRecent()
            } else {
                await search(query)
            }
        }
    }

    private func triggerSearch() {
        if searchText.isEmpty {
            Task { await fetchRecent() }
        } else {
            debouncedSearch(searchText)
        }
    }

    /// Serializes the active date-range picker to `&after=YYYY-MM-DD&before=YYYY-MM-DD`.
    /// The server accepts unix ms too but ISO is easier to debug in the URL.
    private func dateRangeQuery() -> String {
        guard dateRangeActive else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return "&after=\(f.string(from: afterDate))&before=\(f.string(from: beforeDate))"
    }

    private func search(_ query: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        var urlStr = "http://127.0.0.1:\(sonataPort)/api/memory/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&limit=50"
        if typeFilter != "all" { urlStr += "&type=\(typeFilter)" }
        if !projectFilter.isEmpty { urlStr += "&project=\(projectFilter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectFilter)" }
        urlStr += dateRangeQuery()

        guard let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([MemoryItem].self, from: data)
            self.memories = filterByImportance(decoded)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetchRecent() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        var urlStr = "http://127.0.0.1:\(sonataPort)/api/memory/recent?limit=50"
        if typeFilter != "all" { urlStr += "&type=\(typeFilter)" }
        urlStr += dateRangeQuery()

        guard let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([MemoryItem].self, from: data)
            self.memories = filterByImportance(decoded)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetchStats() async {
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/stats") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let stats = try JSONDecoder().decode(MemoryStatsResponse.self, from: data)
            self.totalCount = stats.totalMemories
            self.avgImportance = stats.avgImportance
        } catch {
            // Stats are non-critical
        }
    }

    private func filterByImportance(_ items: [MemoryItem]) -> [MemoryItem] {
        if minImportance <= 0 { return items }
        return items.filter { $0.importance >= minImportance }
    }
}

// MARK: - Memory Row

private struct MemoryListRow: View {
    let memory: MemoryItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: memory.typeIcon)
                .font(.title3)
                .foregroundStyle(memory.typeColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(memory.contentPreview)
                    .font(.body)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(memory.type.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(memory.typeColor.opacity(0.15), in: Capsule())

                    Text(memory.createdDate.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }

            // Importance badge
            Text("\(Int(memory.importance))")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(memory.importanceColor, in: Circle())
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Memory Detail

private struct MemoryDetailView: View {
    let memory: MemoryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: memory.typeIcon)
                        .font(.title)
                        .foregroundStyle(memory.typeColor)
                    Text(memory.type.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.title2.bold())
                    Spacer()
                    Text("Importance: \(Int(memory.importance))")
                        .font(.headline)
                        .foregroundStyle(memory.importanceColor)
                }

                Divider()

                // Content
                Text(memory.content)
                    .font(.body)
                    .textSelection(.enabled)

                Divider()

                // Metadata grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], alignment: .leading, spacing: 12) {
                    MetadataField(label: "ID", value: memory._id)
                    MetadataField(label: "Type", value: memory.type)
                    MetadataField(label: "Importance", value: String(format: "%.1f", memory.importance))
                    MetadataField(label: "Source", value: memory.source ?? "—")
                    MetadataField(label: "Project", value: memory.project ?? "—")
                    MetadataField(label: "Topic", value: memory.topic ?? "—")
                    MetadataField(label: "Status", value: memory.status ?? "active")
                    MetadataField(label: "Access Count", value: "\(memory.accessCount ?? 0)")
                    MetadataField(label: "Created", value: memory.createdDate.formatted(.dateTime))
                    MetadataField(label: "Updated", value: memory.updatedDate.formatted(.dateTime))
                }

                // Tags
                if let tags = memory.tags, !tags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.blue.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }

                // Revision info
                if memory.revisionOf != nil || memory.supersededBy != nil {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Revision History")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let rev = memory.revisionOf {
                            Text("Revision of: \(rev)")
                                .font(.caption.monospaced())
                        }
                        if let sup = memory.supersededBy {
                            Text("Superseded by: \(sup)")
                                .font(.caption.monospaced())
                        }
                        if let note = memory.revisionNote {
                            Text("Note: \(note)")
                                .font(.caption)
                        }
                    }
                }

                // L0/L1 layers
                if memory.l0 != nil || memory.l1 != nil {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Abstraction Layers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let l0 = memory.l0 {
                            Text("L0: \(l0)")
                                .font(.caption)
                        }
                        if let l1 = memory.l1 {
                            Text("L1: \(l1)")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Supporting Views

private struct MetadataField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }
}

/// Simple flow layout for tags
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - Hashable conformance for selection

extension MemoryItem: Hashable {
    static func == (lhs: MemoryItem, rhs: MemoryItem) -> Bool {
        lhs._id == rhs._id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(_id)
    }
}
