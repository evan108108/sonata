import SwiftUI

enum DashboardChatTab: String, CaseIterable, Identifiable {
    case supervisor
    case session

    var id: String { rawValue }
    var label: String {
        switch self {
        case .supervisor: return "Supervisor"
        case .session: return "Session"
        }
    }
}

/// Bottom-anchored two-tab chat strip on the Dashboard. Holds the long-lived
/// view models for the Supervisor (HTTP-backed) and Session (subprocess-backed)
/// tabs as `@StateObject`s so state survives tab switches.
struct DashboardChatStrip: View {
    @StateObject private var supervisorVM = SupervisorChatViewModel()
    @StateObject private var sessionVM = SessionChatViewModel()
    @State private var tab: DashboardChatTab = .supervisor

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            Picker("", selection: $tab) {
                ForEach(DashboardChatTab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ZStack {
                SupervisorChatPanel(vm: supervisorVM)
                    .opacity(tab == .supervisor ? 1 : 0)
                    .allowsHitTesting(tab == .supervisor)

                SessionChatPanel(vm: sessionVM)
                    .opacity(tab == .session ? 1 : 0)
                    .allowsHitTesting(tab == .session)
            }
        }
        .frame(height: 280)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            supervisorVM.setVisible(tab == .supervisor)
        }
        .onChange(of: tab) { _, newValue in
            supervisorVM.setVisible(newValue == .supervisor)
        }
    }
}
