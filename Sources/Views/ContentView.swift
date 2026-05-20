import SwiftUI
import GRDB

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
    case studio = 12
    case sessions = 13
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
    @State private var selectedTab: SonataTab = .sessions
    @State private var inTransit: Bool = false
    @ObservedObject private var workerManager = WorkerManager.shared
    @StateObject private var searchVM = SearchViewModel()
    @StateObject private var unreadCounts = StudioUnreadCounts()
    @StateObject private var railCounts = NavRailCounts()
    @ObservedObject private var deepLink = StudioDeepLinkRouter.shared
    @Environment(\.dbPool) private var dbPool: DatabasePool?
    @FocusState private var searchFocused: Bool

    private var navItems: [NavRailItem] {
        [
            NavRailItem(tab: .dashboard, label: "Dashboard", systemImage: "rectangle.grid.2x2.fill"),
            NavRailItem(tab: .sessions, label: "Sessions", systemImage: "bubble.left.and.bubble.right.fill"),
            NavRailItem(tab: .workers, label: "Workers", systemImage: "terminal.fill", badge: workerManager.busyWorkerCount),
            NavRailItem(tab: .tasks, label: "Tasks", systemImage: "checklist", badge: railCounts.activeTaskCount),
            NavRailItem(tab: .schedule, label: "Schedule", systemImage: "calendar"),
            NavRailItem(tab: .memory, label: "Memory", systemImage: "brain.head.profile"),
            NavRailItem(tab: .wiki, label: "Wiki", systemImage: "book.fill"),
            NavRailItem(tab: .studio, label: "Studio", systemImage: "rectangle.3.group.bubble.fill", badge: unreadCounts.studioTotal),
            NavRailItem(tab: .email, label: "Email", systemImage: "envelope.fill"),
            NavRailItem(tab: .people, label: "People", systemImage: "person.2.fill"),
            NavRailItem(tab: .files, label: "Files", systemImage: "person.text.rectangle"),
            NavRailItem(tab: .plugins, label: "Plugins", systemImage: "puzzlepiece.extension.fill", badge: railCounts.failedPluginCount, badgeIsAlert: true),
            NavRailItem(tab: .settings, label: "Settings", systemImage: "gear"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Warm hairline below the (now transparent) titlebar so there's a
            // defined seam between window chrome and content. Without this the
            // titlebar's traffic-light area bleeds straight into the nav rail
            // / content with no visible boundary.
            Rectangle()
                .fill(Theme.Color.dividerWarm)
                .frame(height: 1)

        HStack(spacing: 0) {
            NavRail(selected: $selectedTab, items: navItems)
            // Warm hairline between rail and content. Replaces the system
            // .separator divider so the seam matches the ember chrome.
            Rectangle()
                .fill(Theme.Color.dividerWarm)
                .frame(width: 1)
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
        // Paint the deepest ember tone behind the whole shell so any view
        // that doesn't draw its own background (e.g. between-pane gaps,
        // the rail's transparent gutter) lands on warm dark instead of the
        // default macOS window gray. Content views with their own neutral
        // surfaces (lists, forms, web dashboards) still paint over this.
        .background(Theme.Color.bgDeep.ignoresSafeArea())
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
        .onAppear {
            if let pool = dbPool {
                unreadCounts.start(dbPool: pool)
                railCounts.start(dbPool: pool)

                // Restore persisted Interactive Sessions tabs from the v14
                // table — bootstrap returns the count it restored. Only
                // auto-spawn "Sonata Default" if NOTHING was restored.
                // Closed-the-default-but-kept-others = no resurrection.
                let restoredCount = InteractiveSessionsViewModel.shared.bootstrap(dbPool: pool)
                if restoredCount == 0, InteractiveSessionsViewModel.shared.tabs.isEmpty {
                    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
                    let cwd = URL(fileURLWithPath: "\(home)/.sonata/session/default")
                    InteractiveSessionsViewModel.shared.addTab(
                        name: "Sonata Default",
                        cwd: cwd
                    )
                }
            }
            // FB15513599 prevention on the INITIAL mount: if the launch tab
            // is a NavigationSplitView one, briefly flash an empty view
            // (one runloop tick) so the NSToolbar gets a clean initial
            // setup. Without this, launching directly into Sessions / Workers
            // / Studio loses toolbar items the same way swap-without-transit
            // does. The .onChange handler below covers subsequent swaps.
            let splitViewTabs: Set<SonataTab> = [.workers, .studio, .sessions]
            if splitViewTabs.contains(selectedTab) {
                inTransit = true
                DispatchQueue.main.async {
                    inTransit = false
                }
            }
        }
        .onChange(of: dbPool.map(ObjectIdentifier.init)) { _, _ in
            if let pool = dbPool {
                unreadCounts.start(dbPool: pool)
                railCounts.start(dbPool: pool)
            }
        }
        // FB15513599 workaround: swapping one NavigationSplitView for another
        // corrupts the window's NSToolbar (sidebar-toggle item gets lost,
        // toolbar items disappear). Hitting a non-NavigationSplitView view
        // in between clears the state. We do that automatically by flashing
        // an empty view for one runloop tick whenever the user switches
        // BETWEEN two NavigationSplitView tabs.
        .onChange(of: selectedTab) { oldValue, newValue in
            let splitViewTabs: Set<SonataTab> = [.workers, .studio, .sessions]
            guard splitViewTabs.contains(oldValue),
                  splitViewTabs.contains(newValue),
                  oldValue != newValue else { return }
            inTransit = true
            DispatchQueue.main.async {
                inTransit = false
            }
        }
        // Switch to the Studio tab whenever a s4a:// invite URL arrives, so
        // the confirm sheet (mounted in StudioView) is on-screen by the
        // time the user notices Sonata came forward. The router's
        // pendingInvite is cleared by the consumer (the sheet itself),
        // not here.
        .onChange(of: deepLink.pendingInvite) { _, newValue in
            guard newValue != nil else { return }
            if selectedTab != .studio {
                selectedTab = .studio
            }
        }
        }  // close VStack opened above to wrap the hairline + HStack
    }

    @ViewBuilder
    private var destinationView: some View {
        if inTransit {
            // One-frame clear pass that owns no NSToolbar items, so the
            // outgoing NavigationSplitView can fully unregister before the
            // incoming one mounts. Background matches the window so the
            // flicker is invisible.
            Theme.Color.bgDeep
        } else {
            actualDestinationView
        }
    }

    @ViewBuilder
    private var actualDestinationView: some View {
        switch selectedTab {
        case .sessions:
            SessionsView()
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
        case .studio:
            StudioView()
        case .dashboard:
            DashboardView(selectedTab: $selectedTab)
        case .settings:
            SettingsView()
        }
    }
}
