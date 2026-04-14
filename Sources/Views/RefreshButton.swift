import SwiftUI

/// Reusable refresh button with stale-data blue dot indicator.
struct RefreshButton: View {
    let isStale: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.clockwise")
                if isStale {
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.borderless)
        .help(isStale ? "New data available — click to refresh" : "Refresh")
    }
}
