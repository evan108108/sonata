import SwiftUI

/// Embedded comment composer pinned to the bottom of the drawer's comment
/// thread. Cmd+↩ submits per §14's keyboard table; plain ↩ inserts a newline.
///
/// Optimistic-insert symmetric with card posting (§15): synthetic comment
/// drops into `store.optimisticComments[clientId]`, server eventId is patched
/// in on success, real comment via ValueObservation drops the optimistic via
/// `reconcileOptimisticCommentsAgainstReal`. On failure the optimistic is
/// rolled back and the body text is restored into the editor so the user can
/// re-edit + Cmd+↩ to retry.
struct StudioCommentCompose: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.studioToast) private var toast

    let roomSlug: String
    let targetEventId: String

    @State private var text: String = ""
    @State private var posting: Bool = false
    @FocusState private var focused: Bool

    var bodyView: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Add a comment…")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .frame(minHeight: 64, maxHeight: 192)
                    .focused($focused)
                    .disabled(posting)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25)))
            }
            HStack(spacing: 8) {
                if posting {
                    ProgressView().controlSize(.small)
                    Text("Posting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(text.count) / 4000")
                    .font(.caption2)
                    .foregroundStyle(text.count > 4000 ? .red : .secondary)
                Spacer()
                Button {
                    submit()
                } label: {
                    Label("Post", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isValid || posting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    var body: some View { bodyView }

    var isValid: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...4000).contains(trimmed.count)
    }

    private func submit() {
        guard isValid, !posting else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entered = text
        let clientId = UUID().uuidString
        let roomCapture = roomSlug
        let targetCapture = targetEventId
        text = ""
        posting = true

        store.optimisticallyInsertComment(
            clientId: clientId,
            roomSlug: roomCapture,
            targetEventId: targetCapture,
            body: trimmed,
            intent: nil
        )

        Task { @MainActor in
            defer { posting = false }
            do {
                let eventId = try await store.postComment(
                    room: roomCapture,
                    targetEventId: targetCapture,
                    body: trimmed,
                    intent: nil
                )
                store.setOptimisticCommentEventId(clientId: clientId, eventId: eventId)
                focused = true
            } catch {
                store.rollbackOptimisticComment(clientId: clientId)
                text = entered
                focused = true
                toast.show(
                    severity: .error,
                    text: "Comment post failed; reverted. \(error.localizedDescription)"
                )
            }
        }
    }
}
