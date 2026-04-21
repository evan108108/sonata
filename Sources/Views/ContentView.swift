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
    case health = 9
    case settings = 0
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

    var body: some View {
        TabView(selection: $selectedTab) {
            WorkersView()
                .tabItem { Label("Workers", systemImage: "terminal.fill") }
                .tag(SonataTab.workers)

            WebDashboardView(filename: "memory.html")
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
                .tag(SonataTab.memory)

            WebDashboardView(filename: "tasks.html")
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(SonataTab.tasks)

            ScheduleView()
                .tabItem { Label("Schedule", systemImage: "calendar") }
                .tag(SonataTab.schedule)

            EmailView()
                .tabItem { Label("Email", systemImage: "envelope.fill") }
                .tag(SonataTab.email)

            ContactsView()
                .tabItem { Label("People", systemImage: "person.2.fill") }
                .tag(SonataTab.people)

            WikiView()
                .tabItem { Label("Wiki", systemImage: "book.fill") }
                .tag(SonataTab.wiki)

            PrivateFilesView()
                .tabItem { Label("Files", systemImage: "person.text.rectangle") }
                .tag(SonataTab.files)

            HealthView()
                .tabItem { Label("Health", systemImage: "heart.text.square.fill") }
                .tag(SonataTab.health)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(SonataTab.settings)
        }
        .padding(.top, 8)
        .focusedSceneValue(\.selectedTab, $selectedTab)
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
}
