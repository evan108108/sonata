import SwiftUI

/// Top-level segmented toggle for a Studio room view: Cards vs Members.
/// Sits between the room header and the per-view content stack so the user
/// can switch context without leaving the room.
enum StudioRoomViewMode: String, CaseIterable, Identifiable {
    case cards
    case members
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cards:   return "Cards"
        case .members: return "Members"
        }
    }
}

struct StudioRoomViewToggle: View {
    @Binding var selection: StudioRoomViewMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(StudioRoomViewMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 220)
    }
}
