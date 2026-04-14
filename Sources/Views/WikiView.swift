import SwiftUI

// MARK: - Models

private struct WikiPage: Identifiable, Decodable, Hashable {
    let _id: String
    let slug: String
    let title: String
    let namespace: String?
    let pageType: String?
    let parentSlug: String?
    let topic: String?
    let lastCompiled: Int64
    let memoryCount: Int
    let dirty: Bool
    let documentId: String?
    let filePath: String
    let abstract: String?
    let createdAt: Int64
    let updatedAt: Int64

    var id: String { _id }

    var lastCompiledDate: Date {
        Date(timeIntervalSince1970: Double(lastCompiled) / 1000)
    }
    var category: String {
        // Derive category from slug: "memory-system" -> top level, "scout/pipeline" -> "scout"
        if let slash = slug.firstIndex(of: "/") {
            return String(slug[slug.startIndex..<slash])
        }
        return ""
    }
    var displayTitle: String {
        title.isEmpty ? slug : title
    }
}

private struct WikiCategory: Identifiable {
    let name: String
    let pages: [WikiPage]
    var id: String { name }

    var displayName: String {
        if name.isEmpty { return "Top Level" }
        return name.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

// MARK: - View

struct WikiView: View {
    @State private var pages: [WikiPage] = []
    @State private var selectedPage: WikiPage?
    @State private var markdownContent: String?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var isLoadingContent = false
    @State private var error: String?
    @State private var recompileSlug: String?

    private var categories: [WikiCategory] {
        let filtered: [WikiPage]
        if searchText.isEmpty {
            filtered = pages
        } else {
            let q = searchText.lowercased()
            filtered = pages.filter {
                $0.title.lowercased().contains(q) ||
                $0.slug.lowercased().contains(q) ||
                ($0.abstract?.lowercased().contains(q) ?? false)
            }
        }

        // Group by category
        let grouped = Dictionary(grouping: filtered) { $0.category }
        return grouped.map { WikiCategory(name: $0.key, pages: $0.value.sorted { $0.slug < $1.slug }) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search wiki pages...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
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

                Divider()
                    .padding(.top, 8)

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
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if categories.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No wiki pages")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedPage) {
                        ForEach(categories) { category in
                            Section(header: Text(category.displayName)) {
                                ForEach(category.pages) { page in
                                    WikiSidebarRow(page: page)
                                        .tag(page)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: selectedPage) { _, newPage in
                        if let page = newPage {
                            Task { await loadMarkdown(for: page) }
                        }
                    }
                }

                // Page count
                Divider()
                HStack {
                    Label("\(pages.count) pages", systemImage: "doc.text.fill")
                    Spacer()
                    let dirtyCount = pages.filter(\.dirty).count
                    if dirtyCount > 0 {
                        Label("\(dirtyCount) dirty", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 260)
        } detail: {
            if let page = selectedPage {
                WikiDetailView(
                    page: page,
                    markdownContent: markdownContent,
                    isLoadingContent: isLoadingContent,
                    onRecompile: {
                        Task { await recompile(slug: page.slug) }
                    }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a wiki page to view")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await fetchPages()
        }
    }

    // MARK: - Networking

    private func fetchPages() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/wiki/pages") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            self.pages = try JSONDecoder().decode([WikiPage].self, from: data)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMarkdown(for page: WikiPage) async {
        isLoadingContent = true
        markdownContent = nil
        defer { isLoadingContent = false }

        // Read the file directly from disk
        let path = page.filePath
        let expandedPath = (path as NSString).expandingTildeInPath
        do {
            markdownContent = try String(contentsOfFile: expandedPath, encoding: .utf8)
        } catch {
            // Try the wiki directory as fallback
            let wikiDir = NSHomeDirectory() + "/.sonata/wiki/"
            let fallbackPath = wikiDir + page.slug + ".md"
            do {
                markdownContent = try String(contentsOfFile: fallbackPath, encoding: .utf8)
            } catch {
                markdownContent = "*Could not load content from:*\n\n`\(expandedPath)`\n\n_Error: \(error.localizedDescription)_"
            }
        }
    }

    private func recompile(slug: String) async {
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/wiki/dirty?slug=\(slug.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? slug)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
        await fetchPages()
    }
}

// MARK: - Sidebar Row

private struct WikiSidebarRow: View {
    let page: WikiPage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pageIcon)
                .foregroundStyle(page.dirty ? .orange : .blue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.displayTitle)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if page.memoryCount > 0 {
                        Label("\(page.memoryCount)", systemImage: "brain.head.profile")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(page.lastCompiledDate.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if page.dirty {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var pageIcon: String {
        switch page.pageType {
        case "category": return "folder.fill"
        case "reference": return "doc.text.magnifyingglass"
        case "project": return "hammer.fill"
        case "feedback": return "bubble.left.fill"
        default: return "doc.text.fill"
        }
    }
}

// MARK: - Detail View

private struct WikiDetailView: View {
    let page: WikiPage
    let markdownContent: String?
    let isLoadingContent: Bool
    let onRecompile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.displayTitle)
                        .font(.title2.bold())
                    HStack(spacing: 12) {
                        if let ns = page.namespace {
                            Text(ns)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.12), in: Capsule())
                        }
                        if let topic = page.topic {
                            Label(topic, systemImage: "tag")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label("\(page.memoryCount) memories", systemImage: "brain.head.profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Compiled \(page.lastCompiledDate.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()

                if page.dirty {
                    Text("DIRTY")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }

                Button {
                    onRecompile()
                } label: {
                    Label("Recompile", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Content
            if isLoadingContent {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if let content = markdownContent {
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(renderMarkdown(content))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
            } else {
                Spacer()
                Text("No content loaded")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Footer with file path
            Divider()
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(page.filePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("ID: \(page._id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    private func renderMarkdown(_ text: String) -> AttributedString {
        do {
            return try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(text)
        }
    }
}
