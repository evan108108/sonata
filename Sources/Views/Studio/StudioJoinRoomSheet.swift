import Foundation
import SwiftUI

/// Paste-an-invite-URL sheet launched from the sidebar's "+ ▾ Join room…"
/// menu. Accepts both the native `4a://invite/...` scheme and the
/// `https://.../invite/...` web fallback; the plugin's `room/join` action
/// resolves either form. On success the joiner's local room lands in one
/// of two states:
///   - `active` — we had a still-valid grant; select the room normally
///     and show a "Joined!" toast.
///   - `pending-grant` — the founder hasn't admitted us yet. Sidebar
///     renders the row greyed with a "joining…" subtitle; the toast says
///     "Waiting for the owner to admit you."
struct StudioJoinRoomSheet: View {
    @ObservedObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss

    /// Notify the parent when a join succeeds. Carries the slug + state so
    /// the sidebar can preselect the row and surface the right toast.
    let onJoined: (_ slug: String, _ state: String) -> Void

    @State private var inviteURL: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submitError: String?

    private var trimmedURL: String {
        inviteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var urlIsValid: Bool {
        StudioJoinRoomSheet.isLikelyInviteURL(trimmedURL)
    }

    private var formIsValid: Bool {
        !trimmedURL.isEmpty && urlIsValid
    }

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
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Join Room")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste an invite link from the room's founder. Native scheme (4a://…) and the https:// fallback both work.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Invite URL")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("4a://invite/… or https://…/invite/…", text: $inviteURL, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2...4)
                if !trimmedURL.isEmpty && !urlIsValid {
                    Text("URL must start with 4a://invite/ or https://…/invite/")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
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
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 6) {
                    if isSubmitting { ProgressView().controlSize(.small) }
                    Text(isSubmitting ? "Joining…" : "Join")
                }
                .frame(minWidth: 70)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!formIsValid || isSubmitting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func submit() async {
        guard formIsValid, !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        do {
            // Pass the default nickname as the volunteered profile preview so
            // the room founder sees identity in the admit dialog. Avatar is
            // intentionally omitted — joiner has no room epoch key yet (see
            // §"privacy" doc-comment on the plugin's room.join handler).
            let nick = store.defaultNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let room = try await store.joinRoom(
                inviteURL: trimmedURL,
                profileNickname: nick.isEmpty ? nil : nick,
                profileBio: nil
            )
            isSubmitting = false
            onJoined(room.slug, room.state)
            dismiss()
        } catch let err as StudioPluginError {
            isSubmitting = false
            submitError = err.message
        } catch {
            isSubmitting = false
            submitError = "Couldn't join room: \(error.localizedDescription)"
        }
    }

    /// Client-side prefix check matching what the plugin's `parseInviteUrl`
    /// will accept. Kept pure + testable so URL validation has unit coverage
    /// without needing to spin up the plugin.
    static func isLikelyInviteURL(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("4a://invite/") { return s.count > "4a://invite/".count }
        if s.hasPrefix("https://"), s.contains("/invite/") { return true }
        return false
    }
}
