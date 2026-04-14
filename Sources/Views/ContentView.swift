import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            WorkersView()
                .tabItem { Label("Workers", systemImage: "terminal.fill") }

            WebDashboardView(filename: "memory.html")
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }

            WebDashboardView(filename: "tasks.html")
                .tabItem { Label("Tasks", systemImage: "checklist") }

            ScheduleView()
                .tabItem { Label("Schedule", systemImage: "calendar") }

            WebDashboardView(filename: "email.html")
                .tabItem { Label("Email", systemImage: "envelope.fill") }

            WikiView()
                .tabItem { Label("Wiki", systemImage: "book.fill") }

            PrivateFilesView()
                .tabItem { Label("Files", systemImage: "person.text.rectangle") }

            HealthView()
                .tabItem { Label("Health", systemImage: "heart.text.square.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .padding(.top, 8)
    }
}

struct PlaceholderTab: View {
    let name: String
    let icon: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("\(name) — coming soon")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
