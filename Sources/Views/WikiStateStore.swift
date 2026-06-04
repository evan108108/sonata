import Foundation
import SwiftUI

/// Wiki page model. Decoded from `GET /api/wiki/pages`.
/// Hoisted out of WikiView so the singleton store can hold it.
struct WikiPage: Identifiable, Decodable, Hashable {
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
        if let slash = slug.firstIndex(of: "/") {
            return String(slug[slug.startIndex..<slash])
        }
        return ""
    }
    var displayTitle: String {
        title.isEmpty ? slug : title
    }
}

/// View-level state for the Wiki feature that needs to survive tab switches.
/// SwiftUI tears down a view's `@State` when its tab is unmounted, which was
/// causing the wiki to lose its current page + expanded folders every time the
/// user navigated away and back. This singleton holds the bits that should
/// persist for the app's lifetime; WikiView just observes it.
///
/// Persistence scope is in-memory only — across tab switches, NOT across app
/// restarts. The user explicitly opted out of UserDefaults persistence for
/// this round; if that becomes wanted later, hydrate from / serialize to
/// UserDefaults in init/didSet.
@MainActor
final class WikiStateStore: ObservableObject {
    static let shared = WikiStateStore()

    @Published var pages: [WikiPage] = []
    @Published var selectedPage: WikiPage?
    @Published var selectedNodeId: String?
    @Published var markdownContent: String?
    @Published var expandedFolderIds: Set<String> = []
    @Published var isLoading = false
    @Published var isLoadingContent = false
    @Published var error: String?

    private init() {}

    /// Two-way Binding for a folder's expansion state — feeds DisclosureGroup
    /// so SwiftUI's expand/collapse writes back to our persistent set.
    func expandedBinding(for nodeId: String) -> Binding<Bool> {
        Binding(
            get: { self.expandedFolderIds.contains(nodeId) },
            set: { isExpanded in
                if isExpanded {
                    self.expandedFolderIds.insert(nodeId)
                } else {
                    self.expandedFolderIds.remove(nodeId)
                }
            }
        )
    }

    func fetchPages(port: Int) async {
        // Don't show the spinner on subsequent loads — pages are already in
        // memory from the first fetch, the refresh is invisible to the user.
        let firstLoad = pages.isEmpty
        if firstLoad { isLoading = true }
        error = nil
        defer { if firstLoad { isLoading = false } }

        guard let url = URL(string: "http://127.0.0.1:\(port)/api/wiki/pages") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            self.pages = try JSONDecoder().decode([WikiPage].self, from: data)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMarkdown(for page: WikiPage) async {
        isLoadingContent = true
        markdownContent = nil
        defer { isLoadingContent = false }

        let expandedPath = (page.filePath as NSString).expandingTildeInPath
        do {
            markdownContent = try String(contentsOfFile: expandedPath, encoding: .utf8)
        } catch {
            // Fallback: ~/.sonata/wiki/<slug>.md (older layout, kept for
            // pages whose filePath got stale between compilations).
            let fallbackPath = NSHomeDirectory() + "/.sonata/wiki/" + page.slug + ".md"
            do {
                markdownContent = try String(contentsOfFile: fallbackPath, encoding: .utf8)
            } catch {
                markdownContent = "*Could not load content from:*\n\n`\(expandedPath)`\n\n_Error: \(error.localizedDescription)_"
            }
        }
    }

    func select(page: WikiPage) async {
        selectedPage = page
        selectedNodeId = "page-\(page.slug)"
        await loadMarkdown(for: page)
    }
}
