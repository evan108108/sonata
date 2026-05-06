import SwiftUI

enum SonataTab: Int, CaseIterable {
    case workers = 1
    case memory = 2
    case tasks = 3
    case schedule = 4
    case email = 5
    case people = 6
    case wiki = 7
    case files = 8
    case dashboard = 9
    case settings = 0
    case plugins = 11
}

// FocusedValue key so .commands{} in SonataApp can switch tabs
struct SelectedTabKey: FocusedValueKey {
    typealias Value = Binding<SonataTab>
}

extension FocusedValues {
    var selectedTab: Binding<SonataTab>? {
        get { self[SelectedTabKey.self] }
        set { self[SelectedTabKey.self] = newValue }
    }
}

struct ContentView: View {
    @State private var selectedTab: SonataTab = .workers
    @ObservedObject private var workerManager = WorkerManager.shared
    @StateObject private var searchVM = SearchViewModel()
    @FocusState private var searchFocused: Bool

    private static let navItems: [NavRailItem] = [
        NavRailItem(tab: .workers, label: "Workers", systemImage: "terminal.fill"),
        NavRailItem(tab: .tasks, label: "Tasks", systemImage: "checklist"),
        NavRailItem(tab: .schedule, label: "Schedule", systemImage: "calendar"),
        NavRailItem(tab: .memory, label: "Memory", systemImage: "brain.head.profile"),
        NavRailItem(tab: .wiki, label: "Wiki", systemImage: "book.fill"),
        NavRailItem(tab: .email, label: "Email", systemImage: "envelope.fill"),
        NavRailItem(tab: .people, label: "People", systemImage: "person.2.fill"),
        NavRailItem(tab: .files, label: "Files", systemImage: "person.text.rectangle"),
        NavRailItem(tab: .plugins, label: "Plugins", systemImage: "puzzlepiece.extension.fill"),
        NavRailItem(tab: .dashboard, label: "Dashboard", systemImage: "rectangle.grid.2x2.fill"),
        NavRailItem(tab: .settings, label: "Settings", systemImage: "gear"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            NavRail(selected: $selectedTab, items: Self.navItems)
            Divider()
            destinationView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if workerManager.isCyclingPaused && selectedTab != .workers {
                        Button {
                            selectedTab = .workers
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pause.circle.fill")
                                    .font(.caption2)
                                Text("Cycling Paused")
                                    .font(.caption2.bold())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.yellow.opacity(0.2), in: Capsule())
                            .foregroundStyle(.yellow)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                        .padding(.top, 4)
                    }
                }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SearchBar(vm: searchVM, focusBinding: $searchFocused)
                    .frame(minWidth: 280, maxWidth: .infinity)
            }
        }
        .overlay {
            if searchVM.isShowingResults {
                SearchOverlay(vm: searchVM, onWiki: { page in
                    searchVM.dismiss()
                    selectedTab = .wiki
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(
                            name: .sonataOpenWikiSlug,
                            object: nil,
                            userInfo: ["slug": page.slug]
                        )
                    }
                })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: searchVM.isShowingResults)
        .focusedSceneValue(\.selectedTab, $selectedTab)
        .focusedSceneValue(\.focusSearchBar) {
            searchFocused = true
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch selectedTab {
        case .workers:
            WorkersView()
        case .memory:
            WebDashboardView(filename: "memory.html")
        case .tasks:
            WebDashboardView(filename: "tasks.html")
        case .schedule:
            ScheduleView()
        case .email:
            EmailView()
        case .people:
            ContactsView()
        case .wiki:
            WikiView()
        case .files:
            PrivateFilesView()
        case .plugins:
            PluginsView()
        case .dashboard:
            DashboardView()
        case .settings:
            SettingsView()
        }
    }
}
