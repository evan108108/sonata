import AppKit
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
///
/// Markdown rendering for the body is handled downstream in `CommentRow`
/// (which reuses `TextBlockView`); the composer itself remains a plain
/// `TextEditor` so the source markdown stays editable.
///
/// Image / file attachments mirror the card compose flow: tap the paperclip
/// or photo button → NSOpenPanel → `studio_image_attach` / `studio_file_attach`
/// → the returned block dict joins `pendingBlocks` as a chip. On submit the
/// dicts ride along in the `blocks` array of `studio_comment_post`.
struct StudioCommentCompose: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.studioToast) private var toast

    let roomSlug: String
    let targetEventId: String

    @State private var text: String = ""
    @State private var posting: Bool = false
    @State private var attaching: Bool = false
    @State private var pendingBlocks: [PendingBlock] = []
    @FocusState private var focused: Bool

    /// One attached image or file waiting to ride along on the next submit.
    /// `payload` is the full block dict the plugin's `studio_comment_post`
    /// embeds verbatim into `blocks[]`. `decoded` is the model representation
    /// the optimistic comment carries so the chip + post-publish row both
    /// render through `StudioBlockView` without redecoding.
    private struct PendingBlock: Identifiable, Equatable {
        let id: UUID = UUID()
        let label: String
        let payload: [String: Any]
        let decoded: StudioBlock

        static func == (lhs: PendingBlock, rhs: PendingBlock) -> Bool {
            lhs.id == rhs.id
        }
    }

    var bodyView: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !pendingBlocks.isEmpty {
                attachmentChips
            }
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
                Button {
                    pickAttachment(asImage: true)
                } label: {
                    Image(systemName: "photo")
                }
                .buttonStyle(.borderless)
                .help("Attach image")
                .disabled(attaching || posting)

                Button {
                    pickAttachment(asImage: false)
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("Attach file")
                .disabled(attaching || posting)

                if attaching {
                    ProgressView().controlSize(.small)
                    Text("Uploading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if posting {
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
                .disabled(!isValid || posting || attaching)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    var body: some View { bodyView }

    private var attachmentChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pendingBlocks) { pb in
                HStack(spacing: 6) {
                    Image(systemName: pb.decoded.chipIcon)
                        .foregroundStyle(.secondary)
                    Text(pb.label)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        pendingBlocks.removeAll { $0.id == pb.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove attachment")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A comment is valid when either the body is non-empty (≤4000) OR at
    /// least one attachment is queued. The card compose flow requires a body,
    /// but a comment that is purely a screenshot or file drop is a common
    /// shape — mirror Slack/Discord rather than the card semantics.
    var isValid: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 4000 { return false }
        if !trimmed.isEmpty { return true }
        return !pendingBlocks.isEmpty
    }

    private func pickAttachment(asImage: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if asImage {
            panel.message = "Attach an image to this comment."
            panel.allowedContentTypes = []
        } else {
            panel.message = "Attach a file to this comment."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        attaching = true
        let path = url.path
        let filename = url.lastPathComponent
        let roomCapture = roomSlug
        Task { @MainActor in
            defer { attaching = false }
            do {
                let dict: [String: Any]
                if asImage {
                    dict = try await store.attachImage(
                        filePath: path,
                        roomSlug: roomCapture,
                        mimeType: nil
                    )
                } else {
                    dict = try await store.attachFile(
                        filePath: path,
                        roomSlug: roomCapture,
                        mimeType: nil
                    )
                }
                guard let decoded = decodeBlock(dict) else {
                    toast.show(severity: .error, text: "Couldn't decode \(filename) attachment.")
                    return
                }
                pendingBlocks.append(
                    PendingBlock(label: filename, payload: dict, decoded: decoded)
                )
            } catch {
                let msg = (error as? StudioPluginError)?.message ?? error.localizedDescription
                toast.show(severity: .error, text: "Attach failed: \(msg)")
            }
        }
    }

    private func decodeBlock(_ dict: [String: Any]) -> StudioBlock? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(StudioBlock.self, from: data)
    }

    private func submit() {
        guard isValid, !posting else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entered = text
        let clientId = UUID().uuidString
        let roomCapture = roomSlug
        let targetCapture = targetEventId
        let blocksCapture = pendingBlocks
        text = ""
        pendingBlocks = []
        posting = true

        store.optimisticallyInsertComment(
            clientId: clientId,
            roomSlug: roomCapture,
            targetEventId: targetCapture,
            body: trimmed,
            intent: nil,
            blocks: blocksCapture.map(\.decoded)
        )

        Task { @MainActor in
            defer { posting = false }
            do {
                let eventId = try await store.postComment(
                    room: roomCapture,
                    targetEventId: targetCapture,
                    body: trimmed,
                    intent: nil,
                    blocks: blocksCapture.map(\.payload)
                )
                store.setOptimisticCommentEventId(clientId: clientId, eventId: eventId)
                focused = true
            } catch {
                store.rollbackOptimisticComment(clientId: clientId)
                text = entered
                pendingBlocks = blocksCapture
                focused = true
                toast.show(
                    severity: .error,
                    text: "Comment post failed; reverted. \(error.localizedDescription)"
                )
            }
        }
    }
}

private extension StudioBlock {
    /// Glyph name used in the pending-attachment chip row.
    var chipIcon: String {
        switch self {
        case .image: return "photo"
        case .file:  return "paperclip"
        case .text:  return "text.alignleft"
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .link:  return "link"
        case .field: return "tablecells"
        case .unknown: return "questionmark.square"
        }
    }
}
