import SwiftUI

/// Three-way segmented filter pinned to the top of the rooms sidebar. Lets
/// the user hide closed rooms by default while still being able to surface
/// them on demand via the All / Closed views.
enum StudioRoomFilter: String, CaseIterable, Identifiable {
    case active
    case closed
    case all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: return "Active"
        case .closed: return "Closed"
        case .all:    return "All"
        }
    }
}

struct StudioRoomFilterBar: View {
    @Binding var selection: StudioRoomFilter

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(StudioRoomFilter.allCases) { f in
                Text(f.label).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
