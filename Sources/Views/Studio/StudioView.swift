import Foundation
import SwiftUI
import GRDB

struct StudioView: View {
    @Environment(\.dbPool) private var dbPool: DatabasePool?
    @StateObject private var store = StudioStore()
    @ObservedObject private var deepLink = StudioDeepLinkRouter.shared

    @State private var selectedRoom: StudioRoom?
    @State private var pendingInviteJoined: (slug: String, state: String)?

    var body: some View {
        NavigationSplitView {
            StudioRoomList(
                store: store,
                selectedRoom: $selectedRoom
            )
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            // Resolve `selectedRoom` through the live `store.rooms` array on
            // every render — without this, the detail pane keeps the snapshot
            // captured at click time, so post-admit changes (members count,
            // pending pill, refreshed title) only land after the user clicks
            // off-and-back. The id-based lookup keeps SwiftUI's identity stable
            // across observation ticks.
            if let selected = selectedRoom,
               let current = store.rooms.first(where: { $0.id == selected.id }) {
                StudioRoomDetail(room: current, store: store)
                    .id(current.id)
            } else {
                StudioPickRoomPlaceholder()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if let pool = dbPool {
                store.start(dbPool: pool)
            }
        }
        .onChange(of: dbPool.map(ObjectIdentifier.init)) { _, _ in
            if let pool = dbPool {
                store.start(dbPool: pool)
            }
        }
        .onDisappear {
            store.stop()
        }
        // 4a:// invite arrived via the URL handler. Present a confirm sheet
        // bound to the router's pending invite; the sheet calls back with
        // the joined room slug + state so we can select it in the sidebar.
        .sheet(
            item: Binding(
                get: { deepLink.pendingInvite },
                set: { newValue in
                    if newValue == nil { deepLink.pendingInvite = nil }
                }
            )
        ) { invite in
            StudioInviteConfirmSheet(
                store: store,
                pending: invite,
                onJoined: { slug, state in
                    deepLink.pendingInvite = nil
                    pendingInviteJoined = (slug, state)
                },
                onCancel: {
                    deepLink.pendingInvite = nil
                }
            )
        }
        // After the join request returns, find the joined room (it may
        // already be in store.rooms via the SSE projector, or it will land
        // in the next observation tick) and select it.
        .onChange(of: pendingInviteJoined?.slug) { _, slug in
            guard let slug else { return }
            if let room = store.rooms.first(where: { $0.slug == slug }) {
                selectedRoom = room
                pendingInviteJoined = nil
            }
        }
        .onChange(of: store.rooms.map(\.slug)) { _, _ in
            guard let pending = pendingInviteJoined,
                  let room = store.rooms.first(where: { $0.slug == pending.slug }) else { return }
            selectedRoom = room
            pendingInviteJoined = nil
        }
    }
}

private struct StudioPickRoomPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group.bubble.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Pick a room")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select a room from the sidebar, or press ⌘N to create one.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

