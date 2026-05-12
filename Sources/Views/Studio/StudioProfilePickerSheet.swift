import AppKit
import SwiftUI

/// Single sheet that lets the user choose which profile to publish into a
/// newly-created or just-joined room. Two paths:
///   - **Default**: federate the machine-local defaults (nickname + avatar).
///   - **New for this room**: pick a one-off nickname + optional avatar
///     specific to this room.
///
/// "Skip" closes the sheet without publishing — same shape as the legacy
/// auto-publish-on-first-post behavior, so users who decline still federate
/// their default profile as soon as they post their first card.
///
/// "Use this profile" calls `StudioStore.publishProfileCard(...)`. When the
/// room is in `pending-grant` state (joiner waiting on founder admit), the
/// publish is queued via `StudioStore.deferProfilePublish(...)` and the
/// picker closes; the deferred entry fires once the room transitions to
/// `active`.
struct StudioProfilePickerSheet: View {
    @ObservedObject var store: StudioStore
    let roomSlug: String
    let roomTitle: String
    /// Whether to bypass the deferred-publish path and force an immediate
    /// publish attempt. Used by the per-room editor where the room is
    /// already active.
    var forceImmediatePublish: Bool = false
    /// Pre-populate with the current per-room profile (used by the editor
    /// variant). Nil for the post-create / post-join variants, which start
    /// with "Default" selected.
    var initialPerRoomNickname: String? = nil
    var initialPerRoomAvatarPath: String? = nil

    @Environment(\.dismiss) private var dismiss

    enum Choice: String, CaseIterable, Identifiable {
        case useDefault
        case custom
        var id: String { rawValue }
    }

    @State private var choice: Choice = .useDefault
    @State private var customNickname: String = ""
    @State private var customAvatarPath: String? = nil
    @State private var submitting: Bool = false
    @State private var errorMessage: String? = nil
    @State private var pickerError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            footer
        }
        .frame(width: 480)
        .onAppear { populateInitialState() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text("Use which profile for \(roomTitle.isEmpty ? roomSlug : roomTitle)?")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $choice) {
                Text("Default").tag(Choice.useDefault)
                Text("New for this room").tag(Choice.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch choice {
            case .useDefault:
                defaultPreview
            case .custom:
                customForm
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var defaultPreview: some View {
        HStack(alignment: .center, spacing: 12) {
            StudioLocalAvatarPreview(path: store.defaultAvatarLocalPath, diameter: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.defaultNickname.isEmpty ? "(no default nickname set)" : store.defaultNickname)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(store.defaultNickname.isEmpty ? .secondary : .primary)
                if store.defaultNickname.isEmpty {
                    Text("Set one in Settings → Studio, or pick \"New for this room\" below.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("From Settings → Studio. Federated to every member of this room.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var customForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                StudioLocalAvatarPreview(path: customAvatarPath, diameter: 48)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button("Choose avatar…") { pickCustomAvatar() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Clear") { customAvatarPath = nil }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(customAvatarPath == nil)
                    }
                    if let err = pickerError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Optional. Re-encrypted per room.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Nickname")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. scout-evan", text: $customNickname)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await submit() } }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Skip") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(submitting)
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 6) {
                    if submitting { ProgressView().controlSize(.small) }
                    Text(submitButtonLabel)
                }
                .frame(minWidth: 130)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(submitting || !submitIsValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var submitButtonLabel: String {
        switch choice {
        case .useDefault:
            return store.defaultNickname.isEmpty ? "No default set" : "Use default"
        case .custom:
            return "Use this profile"
        }
    }

    private var submitIsValid: Bool {
        switch choice {
        case .useDefault:
            return !store.defaultNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .custom:
            let trimmed = customNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            return (1...200).contains(trimmed.count)
        }
    }

    private func populateInitialState() {
        if let nick = initialPerRoomNickname, !nick.isEmpty {
            customNickname = nick
            choice = .custom
        }
        if let path = initialPerRoomAvatarPath, !path.isEmpty {
            customAvatarPath = path
            choice = .custom
        }
    }

    private func pickCustomAvatar() {
        pickerError = nil
        do {
            guard let path = try StudioAvatarPicker.pickAndStage() else { return }
            customAvatarPath = path
        } catch {
            pickerError = error.localizedDescription
        }
    }

    private func submit() async {
        guard submitIsValid, !submitting else { return }
        submitting = true
        errorMessage = nil
        defer { submitting = false }

        let nick: String
        let avatarPath: String?
        switch choice {
        case .useDefault:
            nick = store.defaultNickname
            avatarPath = store.defaultAvatarLocalPath
        case .custom:
            nick = customNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            avatarPath = customAvatarPath
        }

        let isPendingGrant = !forceImmediatePublish
            && (store.rooms.first(where: { $0.slug == roomSlug })?.state == "pending-grant")

        if isPendingGrant {
            store.deferProfilePublish(roomSlug: roomSlug, nickname: nick, avatarLocalPath: avatarPath)
            dismiss()
            return
        }

        do {
            _ = try await store.publishProfileCard(
                roomSlug: roomSlug,
                nickname: nick,
                avatarLocalPath: avatarPath
            )
            // Remember the per-room custom path so the next open of the
            // picker shows what the user chose. "Use default" clears the
            // entry — the picker's Default tab is the source of truth then.
            switch choice {
            case .useDefault:
                await store.setRoomAvatarLocalPath(roomSlug: roomSlug, path: nil)
            case .custom:
                await store.setRoomAvatarLocalPath(roomSlug: roomSlug, path: customAvatarPath)
            }
            dismiss()
        } catch let err as StudioPluginError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
