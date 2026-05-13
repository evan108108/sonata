import Foundation
import SwiftUI

/// Sheet shown when the user clicks a `4a://invite/...` URL from anywhere
/// (Messages, Mail, shell `open`, etc.). Reuses the pasted-URL join path
/// — `store.joinRoom(inviteURL:)` — but pre-fills the URL and shows a
/// founder-recognizable preview (slug + epoch) before the user commits.
///
/// Intentionally a thin wrapper around the existing join action: we do not
/// duplicate the plugin's URL parsing or validation. If the URL is malformed
/// the plugin call returns a `StudioPluginError` and we surface its `message`.
struct StudioInviteConfirmSheet: View {
    @ObservedObject var store: StudioStore
    let pending: StudioDeepLinkRouter.PendingInvite

    /// Notify the parent when the join lands so it can mark the new room
    /// selected in the sidebar. Mirrors `StudioJoinRoomSheet.onJoined`.
    let onJoined: (_ slug: String, _ state: String) -> Void
    let onCancel: () -> Void

    @State private var isSubmitting: Bool = false
    @State private var submitError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Join room from link")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Someone shared a Sonata Studio room with you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if let slug = pending.previewSlug {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Room")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.3.group.bubble.fill")
                            .foregroundStyle(.secondary)
                        Text(slug)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                        if let epoch = pending.previewEpoch {
                            Text("· epoch \(epoch)")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Invite URL")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(pending.rawURL)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }

            if let err = submitError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 6) {
                    if isSubmitting { ProgressView().controlSize(.small) }
                    Text(isSubmitting ? "Joining…" : "Join room")
                }
                .frame(minWidth: 90)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        do {
            let nick = store.defaultNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let room = try await store.joinRoom(
                inviteURL: pending.rawURL,
                profileNickname: nick.isEmpty ? nil : nick,
                profileBio: nil
            )
            isSubmitting = false
            onJoined(room.slug, room.state)
        } catch let err as StudioPluginError {
            isSubmitting = false
            submitError = err.message
        } catch {
            isSubmitting = false
            submitError = "Couldn't join room: \(error.localizedDescription)"
        }
    }
}
