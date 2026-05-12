import SwiftUI

/// Horizontal scroll of selectable track tabs for the active room. Includes:
///   - a leading "All" pseudo-tab (selection: `selectedTrack == nil`)
///   - one tab per `StudioTrack` in `store.tracks[room.slug]`, ordered by
///     most-recent activity DESC (auto-created stubs without cards land at
///     the right because their `lastActivityAt` collapses to .min)
///   - a trailing "Dispatch trace" pseudo-tab iff `showDispatchTrace` is true
struct StudioTrackBar: View {
    /// Sentinel selectedTrack value for the dispatch-trace pseudo-tab. Track
    /// regex (`^[A-Za-z0-9-]{1,64}$`) rejects underscores, so this cannot
    /// collide with a real track name.
    static let dispatchTraceTag: String = "__studio_dispatch_trace__"

    let room: StudioRoom
    @ObservedObject var store: StudioStore
    @Binding var selectedTrack: String?
    @Binding var showDispatchTrace: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                allTab
                ForEach(orderedTracks, id: \.id) { track in
                    trackTab(track)
                }
                if showDispatchTrace {
                    dispatchTab
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ordering

    private var orderedTracks: [StudioTrack] {
        let all = store.tracks[room.slug] ?? []
        return all.sorted { a, b in
            let av = store.lastActivityAt(track: a, in: room.slug) ?? Int64.min
            let bv = store.lastActivityAt(track: b, in: room.slug) ?? Int64.min
            if av != bv { return av > bv }
            return a.name < b.name
        }
    }

    // MARK: - Tabs

    private var allTab: some View {
        capsuleButton(
            label: "All",
            symbol: nil,
            italic: false,
            selected: selectedTrack == nil,
            help: "All tracks in this room.",
            action: { selectedTrack = nil }
        )
    }

    private func trackTab(_ track: StudioTrack) -> some View {
        capsuleButton(
            label: track.title.isEmpty ? track.name : track.title,
            symbol: nil,
            italic: track.autoCreated,
            selected: selectedTrack == track.name,
            help: track.autoCreated
                ? "auto-created — awaiting Track event"
                : (track.description ?? "Track: \(track.name)"),
            action: { selectedTrack = track.name }
        )
    }

    private var dispatchTab: some View {
        capsuleButton(
            label: "Dispatch trace",
            symbol: "arrow.up.right.diamond",
            italic: false,
            selected: selectedTrack == Self.dispatchTraceTag,
            help: "Worker selection traces for this room (DESC by created_at_ms).",
            action: { selectedTrack = Self.dispatchTraceTag }
        )
    }

    // MARK: - Capsule

    @ViewBuilder
    private func capsuleButton(
        label: String,
        symbol: String?,
        italic: Bool,
        selected: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .italic(italic)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? Color.accentColor : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? Color.clear : Color.secondary.opacity(0.35),
                    lineWidth: 1
                )
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
