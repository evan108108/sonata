import SwiftUI

/// Main pane of the Studio tab when a room is selected. Renders header,
/// horizontal track bar, and the card list. Two `@State` values are local:
///   - `selectedTrack`: nil ↔ "all tracks"; non-nil ↔ a specific track name
///     (or the dispatch-trace sentinel — see `StudioTrackBar.dispatchTraceTag`).
///   - `showDispatchTrace`: mirrors `studio_room.attributes.dispatch_trace_on`,
///     initialized from the `room` snapshot, persisted back via
///     `store.setDispatchTraceOn(slug:_:)` on toggle.
struct StudioRoomDetail: View {
    let room: StudioRoom
    @ObservedObject var store: StudioStore

    @State private var selectedTrack: String? = nil
    @State private var showDispatchTrace: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            StudioTrackBar(
                room: room,
                store: store,
                selectedTrack: $selectedTrack,
                showDispatchTrace: $showDispatchTrace
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            StudioCardList(
                room: room,
                track: selectedTrack,
                dispatchTrace: dispatchTraceActive,
                store: store
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            showDispatchTrace = room.dispatchTraceOn
            store.openRoom(room.slug)
            store.markRoomSeen(room.slug)
        }
        .onDisappear {
            store.closeRoom(room.slug)
        }
        .onChange(of: room.slug) { _, newSlug in
            store.closeRoom(room.slug)
            selectedTrack = nil
            showDispatchTrace = room.dispatchTraceOn
            store.openRoom(newSlug)
            store.markRoomSeen(newSlug)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(room.title.isEmpty ? room.slug : room.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if room.state == "pending-grant" {
                        pendingPill
                    }
                }
                Text(memberLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            settingsMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var pendingPill: some View {
        Text("joining…")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.yellow.opacity(0.85), in: Capsule())
            .help("Awaiting epoch-key grant from the room founder.")
    }

    private var memberLine: String {
        let n = room.members.count
        return n == 1 ? "1 member" : "\(n) members"
    }

    private var settingsMenu: some View {
        Menu {
            Toggle(isOn: dispatchTraceBinding) {
                Label("Show dispatch trace", systemImage: "arrow.up.right.diamond")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Room settings")
    }

    // MARK: - Bindings

    private var dispatchTraceBinding: Binding<Bool> {
        Binding(
            get: { showDispatchTrace },
            set: { newValue in
                showDispatchTrace = newValue
                Task { await store.setDispatchTraceOn(slug: room.slug, newValue) }
                if !newValue && selectedTrack == StudioTrackBar.dispatchTraceTag {
                    selectedTrack = nil
                }
            }
        )
    }

    // MARK: - Derived

    private var dispatchTraceActive: Bool {
        showDispatchTrace && selectedTrack == StudioTrackBar.dispatchTraceTag
    }
}
