import SwiftUI

/// Per-room nickname editor. Opened from the room gear menu. Pre-populates
/// from the local user's current per-room nickname, falling back to the
/// machine-local default. Save publishes a `_profile` card with the same
/// per-author d_tag (`profile:<pubkey>`) so re-saves overwrite the prior
/// rumor everywhere it was delivered.
struct StudioRoomProfileSheet: View {
    @ObservedObject var store: StudioStore
    let roomSlug: String
    let roomTitle: String

    @Environment(\.dismiss) private var dismiss

    @State private var nickname: String = ""
    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your nickname in #\(roomTitle)")
                    .font(.headline)
                Text("Visible to every other member of this room. Saves a hidden `_profile` card so the rest of the audience sees your new name within a couple seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("Nickname (1–200 chars)", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Text("\(nickname.count) / 200")
                    .font(.caption2)
                    .foregroundStyle(nickname.count > 200 ? .red : .secondary)
            }

            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: save) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving || !isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { nickname = store.currentRoomNickname(for: roomSlug) }
    }

    private var isValid: Bool {
        let t = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...200).contains(t.count)
    }

    private func save() {
        guard isValid, !saving else { return }
        saving = true
        errorMessage = nil
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await store.publishProfileCard(roomSlug: roomSlug, nickname: trimmed)
                dismiss()
            } catch {
                errorMessage = (error as? StudioPluginError)?.message ?? error.localizedDescription
            }
        }
    }
}
