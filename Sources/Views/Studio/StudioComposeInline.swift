import SwiftUI

/// Single-line compose strip pinned to the bottom of the active track column.
///
/// Posts as `kind: "note"` with the entered text becoming the card `body`.
/// Title is derived as the first 60 chars of body (trimmed of trailing
/// whitespace); per W6.1 the plugin re-validates so the cheap derivation is
/// safe client-side.
///
/// Optimistic-insert flow per §15:
///   1. Generate clientId, build a synthetic StudioCard via the store, drop
///      it into `optimisticCards`.
///   2. Clear `text` immediately so the user can keep typing.
///   3. Fire `store.postCard(...)` on a Task; on success patch eventId via
///      `store.setOptimisticEventId(clientId:eventId:)`; on failure roll
///      back and surface a toast plus a retry button that restores the
///      original text.
struct StudioComposeInline: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.studioToast) private var toast

    let roomSlug: String
    let trackSlug: String

    @State private var text: String = ""
    @State private var lastFailed: String? = nil
    @State private var inFlight: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Drop a thought in #\(trackSlug)", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(inFlight)
                .onSubmit { submit() }

            if lastFailed != nil {
                Button {
                    text = lastFailed ?? ""
                    lastFailed = nil
                    focused = true
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Retry last failed post")
            }

            if inFlight {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func submit() {
        let bodyText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bodyText.isEmpty, !inFlight else { return }
        let title = String(bodyText.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        let clientId = UUID().uuidString
        let entered = text
        text = ""
        lastFailed = nil
        inFlight = true

        store.optimisticallyInsertCard(
            clientId: clientId,
            roomSlug: roomSlug,
            trackSlug: trackSlug,
            kind: "note",
            title: title,
            body: bodyText,
            blocks: [],
            tagsList: [],
            relatedTo: []
        )

        Task { @MainActor in
            defer { inFlight = false }
            do {
                let eventId = try await store.postCard(
                    room: roomSlug,
                    track: trackSlug,
                    kind: "note",
                    title: title,
                    body: bodyText,
                    blocks: [],
                    relatedTo: [],
                    tagsList: [],
                    dTag: nil
                )
                store.setOptimisticEventId(clientId: clientId, eventId: eventId)
            } catch {
                store.rollbackOptimisticCard(clientId: clientId)
                lastFailed = entered
                toast.show(
                    severity: .error,
                    text: "Post failed; reverted. \(error.localizedDescription)"
                )
            }
        }
    }
}
