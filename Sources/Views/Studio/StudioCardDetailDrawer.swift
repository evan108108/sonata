import AppKit
import SwiftUI

/// Slide-in drawer for a single `StudioCard`. Width 420pt. Three sticky
/// regions: header (icon + title + actions + close), scrolling body (foldable
/// blocks + divider + comments), bottom compose-stub. T2 owns the trailing
/// overlay + dismiss-zone; this file ships the drawer body.
struct StudioCardDetailDrawer: View {
    let card: StudioCard
    @ObservedObject var store: StudioStore
    let fetcher: StudioImageFetcher
    @Binding var selectedCard: StudioCard?

    var onEnrich: ((StudioCard) -> Void)? = nil
    var onOpenPR: ((StudioCard) -> Void)? = nil
    var onAnswer: ((StudioCard) -> Void)? = nil
    /// Called when the user clicks the drawer-header pencil. The parent
    /// dismisses the drawer first, then opens the edit sheet on the same card.
    var onEdit: ((StudioCard) -> Void)? = nil

    @State private var showDeleteConfirm: Bool = false
    @State private var deleteErrorMessage: String? = nil
    @State private var transitionErrorMessage: String? = nil
    /// Optimistic local override for the segmented status while the wire
    /// round-trip lands. The transition publishes a status_change comment,
    /// the projector flips the card entity's status, and the SSE update
    /// flows back here — typically within a second on local. Until then,
    /// the segmented control needs to render the user's choice rather than
    /// the unchanged card.lifecycleStatus, otherwise it visibly snaps back.
    /// Cleared when the observed card status matches our pending choice.
    @State private var pendingStatus: String? = nil
    @State private var assignErrorMessage: String? = nil
    @State private var showAssignPicker: Bool = false
    @State private var auditFoldOpen: Bool = false

    private var meHex: String { store.currentPubkeyHex.lowercased() }

    private var canMutate: Bool {
        !card.createdByPubkey.isEmpty &&
            card.createdByPubkey.lowercased() == meHex &&
            !card.dTag.isEmpty
    }

    /// True if the local user is the assigned pubkey for this card. Drives
    /// permission gating for the in_progress / done segments of the status
    /// picker when the caller isn't also the author.
    private var isAssignee: Bool {
        guard let pk = card.assigneePubkey, !pk.isEmpty else { return false }
        return pk == meHex
    }

    private var canTransition: Bool { canMutate || isAssignee }
    private var canDelete: Bool { canMutate }
    private var canEdit: Bool { canMutate }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            Divider()
            controlsRow
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    authorByline
                    if !card.body.isEmpty {
                        // Render the body as markdown above the block list,
                        // reusing TextBlockView so the visual matches inline
                        // text blocks (which already render markdown).
                        TextBlockView(text: card.body)
                    }
                    blockList
                    Divider()
                    commentThread
                }
                .padding(16)
            }
            Divider()
            StudioCommentCompose(roomSlug: card.roomSlug, targetEventId: card.eventId)
                .environmentObject(store)
        }
        .frame(width: 420)
        .background(Color(NSColor.windowBackgroundColor))
        .contentShape(Rectangle())
        .transition(.move(edge: .trailing))
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: StudioCardRow.symbol(for: card.cardKind))
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)

            Text(card.title.isEmpty ? "(untitled)" : card.title)
                .font(.title3)
                .lineLimit(2)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            kindActionButtons

            if canEdit {
                Button {
                    let captured = card
                    selectedCard = nil
                    onEdit?(captured)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Edit card")
            }

            if canDelete {
                Menu {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete card…", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }

            Button {
                selectedCard = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close drawer (Esc)")
        }
        .confirmationDialog(
            "Delete this card?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let eventId = card.eventId
                let dTag = card.dTag
                let roomSlug = card.roomSlug
                Task {
                    do {
                        try await store.deleteCard(roomSlug: roomSlug, dTag: dTag, eventId: eventId)
                        await MainActor.run { selectedCard = nil }
                    } catch {
                        await MainActor.run {
                            deleteErrorMessage = (error as? StudioPluginError)?.message ?? error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Deleted cards can't be restored.")
        }
        .alert(
            "Couldn't delete card",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var kindActionButtons: some View {
        HStack(spacing: 6) {
            if card.cardKind == "lead" {
                Button("Enrich") { onEnrich?(card) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if card.cardKind == "review" {
                Button("Open PR") { onOpenPR?(card) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(reviewPRHref == nil)
            }
            if card.cardKind == "question" {
                Button("Answer") { onAnswer?(card) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    /// For a `review` card, the Open PR button reads a link block whose label
    /// equals `PR` (case-insensitive trim). Returns nil if none present.
    private var reviewPRHref: String? {
        for b in card.blocks {
            if case .link(let href, let label) = b,
               (label ?? "").trimmingCharacters(in: .whitespaces) == "PR" {
                return href
            }
        }
        return nil
    }

    // MARK: - Controls row (status + assignee)

    @ViewBuilder
    private var controlsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("Status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                statusSegmented
                if canMutate, card.lifecycleStatus != "archived" {
                    Button("Archive…") { transition(to: "archived") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Archive this card (author only)")
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 8) {
                Text("Assign")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                if let pk = card.assigneePubkey, !pk.isEmpty {
                    StudioAvatarView(store: store, pubkeyHex: pk, roomSlug: card.roomSlug, diameter: 18)
                    Text(store.displayName(for: pk, in: card.roomSlug))
                        .font(.system(size: 12))
                } else {
                    Text("Unassigned")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if canMutate {
                    Button(card.assigneePubkey == nil ? "Assign…" : "Reassign…") {
                        showAssignPicker = true
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .popover(isPresented: $showAssignPicker, arrowEdge: .bottom) {
                        AssigneePickerPopover(
                            store: store,
                            roomSlug: card.roomSlug,
                            currentAssignee: card.assigneePubkey,
                            onPick: { pk in
                                showAssignPicker = false
                                reassign(to: pk)
                            }
                        )
                    }
                }
                Spacer(minLength: 0)
            }
            if let msg = transitionErrorMessage {
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if let msg = assignErrorMessage {
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var statusSegmented: some View {
        // Render the pending optimistic value while a transition is in flight;
        // otherwise read straight off the card. onChange below clears the
        // pending state once the projected card catches up.
        let current = pendingStatus ?? card.lifecycleStatus
        // Picker with three primary states. Archive is sidebar'd to keep the
        // segmented control narrow. When the card is archived, we surface it
        // as the "active" segment via a single read-only chip.
        if current == "archived" {
            HStack(spacing: 4) {
                Image(systemName: "archivebox")
                Text("Archived")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
            Picker("", selection: Binding(
                get: { current },
                set: { transition(to: $0) }
            )) {
                Text("Open").tag("open")
                Text("In progress").tag("in_progress")
                Text("Done").tag("done")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .disabled(!canTransition)
            .help(canTransition
                ? "Move card through its lifecycle"
                : "Only the author or current assignee can change status")
            .onChange(of: card.lifecycleStatus) { _, observed in
                if pendingStatus == observed { pendingStatus = nil }
            }
        }
    }

    private func transition(to next: String) {
        guard next != (pendingStatus ?? card.lifecycleStatus) else { return }
        let roomSlug = card.roomSlug
        let dTag = card.dTag
        // Optimistic UI: hold the user's pick while the publish-project-SSE
        // round-trip lands. Cleared by the .onChange above when the observed
        // card.lifecycleStatus catches up, or by the catch block on failure.
        pendingStatus = next
        Task {
            do {
                _ = try await store.transitionCardStatus(
                    roomSlug: roomSlug,
                    dTag: dTag,
                    status: next
                )
                await MainActor.run { transitionErrorMessage = nil }
            } catch {
                await MainActor.run {
                    transitionErrorMessage = (error as? StudioPluginError)?.message ?? error.localizedDescription
                    pendingStatus = nil
                }
            }
        }
    }

    private func reassign(to pubkeyHex: String?) {
        let roomSlug = card.roomSlug
        let dTag = card.dTag
        let eventId = card.eventId
        Task {
            do {
                _ = try await store.updateCardAssignee(
                    roomSlug: roomSlug,
                    dTag: dTag,
                    eventId: eventId,
                    assigneePubkey: pubkeyHex
                )
                await MainActor.run { assignErrorMessage = nil }
            } catch {
                await MainActor.run {
                    assignErrorMessage = (error as? StudioPluginError)?.message ?? error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var authorByline: some View {
        HStack(spacing: 8) {
            StudioAvatarView(
                store: store,
                pubkeyHex: card.createdByPubkey,
                roomSlug: card.roomSlug,
                diameter: 24
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayName(for: card.createdByPubkey, in: card.roomSlug))
                    .font(.system(size: 12, weight: .medium))
                Text(StudioCardRow.relativeTime(from: card.createdAtSeconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Block list (foldable)

    @ViewBuilder
    private var blockList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(card.blocks.enumerated()), id: \.offset) { _, block in
                FoldableBlock(block: block) {
                    StudioBlockView(
                        block: block,
                        roomSlug: card.roomSlug,
                        authorPubHex: card.createdByPubkey,
                        fetcher: fetcher,
                        dispatchTraceOn: dispatchTraceOn,
                        canReshareFile: canMutate,
                        onReshareFile: { f in reshareFile(f) }
                    )
                }
            }
        }
    }

    /// Re-share path for a file block. The plugin doesn't keep the original
    /// plaintext on disk — Blossom holds the canonical ciphertext bytes — so
    /// "Re-share" requires the author to re-pick the same file with
    /// NSOpenPanel. The new fileAttach result replaces the matched block in
    /// the card's blocks[] (by filename + sha256), and we publish via
    /// studio_card_update keeping the same d_tag.
    private func reshareFile(_ original: StudioFileBlock) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Re-share \(original.filename): pick the same file to re-wrap its key to the current room epoch."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let captureCard = card
        let captureRoom = card.roomSlug
        Task { @MainActor in
            do {
                let block = try await store.attachFile(
                    filePath: url.path,
                    roomSlug: captureRoom,
                    mimeType: original.mimeType
                )
                let newBlocks = Self.replaceFileBlock(
                    in: captureCard.blocks,
                    matching: original,
                    with: block
                )
                _ = try await store.updateCard(
                    roomSlug: captureCard.roomSlug,
                    dTag: captureCard.dTag,
                    eventId: captureCard.eventId,
                    track: nil,
                    kind: nil,
                    title: nil,
                    body: nil,
                    blocks: newBlocks,
                    tagsList: nil,
                    relatedTo: nil,
                    assigneePubkey: nil
                )
            } catch {
                transitionErrorMessage = "Re-share failed: \((error as? StudioPluginError)?.message ?? error.localizedDescription)"
            }
        }
    }

    /// Build a fresh blocks[] payload for `studio_card_update` by replacing
    /// the file block matching `original` (by filename + sha256) with the
    /// freshly-uploaded `replacement` dict. Other blocks round-trip back to
    /// their on-the-wire dict shape so the update preserves card content.
    static func replaceFileBlock(
        in blocks: [StudioBlock],
        matching original: StudioFileBlock,
        with replacement: [String: Any]
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for b in blocks {
            switch b {
            case .file(let f) where f.filename == original.filename && f.sha256 == original.sha256:
                out.append(replacement)
            case .text(let body):
                out.append(["type": "text", "body": body])
            case .code(let lang, let body):
                out.append(["type": "code", "language": lang, "body": body])
            case .link(let href, let label):
                var p: [String: Any] = ["type": "link", "href": href]
                if let l = label, !l.isEmpty { p["label"] = l }
                out.append(p)
            case .field(let k, let v):
                out.append(["type": "field", "key": k, "value": v])
            case .image(let img):
                out.append([
                    "type": "image",
                    "sha256": img.sha256,
                    "mirrors": img.mirrors,
                    "decrypt_hint": [
                        "kind": img.decryptHint.kind,
                        "epoch_n": img.decryptHint.epochN,
                    ],
                    "mime_type": img.mimeType,
                    "blake3": img.blake3,
                ])
            case .file(let f):
                out.append([
                    "type": "file",
                    "filename": f.filename,
                    "mime_type": f.mimeType,
                    "size_bytes": f.sizeBytes,
                    "sha256": f.sha256,
                    "blake3": f.blake3,
                    "mirrors": f.mirrors,
                    "decrypt_hint": [
                        "kind": f.decryptHint.kind,
                        "epoch_n": f.decryptHint.epochN,
                        "wrapped_key": f.decryptHint.wrappedKey,
                    ],
                ])
            case .unknown(let t, _):
                out.append(["type": t])
            }
        }
        return out
    }

    private var dispatchTraceOn: Bool {
        store.rooms.first(where: { $0.slug == card.roomSlug })?.dispatchTraceOn ?? false
    }

    // MARK: - Comment thread

    @ViewBuilder
    private var commentThread: some View {
        let real = store.comments(forCard: card.eventId)
        let optimisticIds = Set(optimisticCommentsForCard.map(\.id))
        let merged = (optimisticCommentsForCard + real)
            .sorted(by: { $0.createdAtSeconds < $1.createdAtSeconds })
        let regular = merged.filter { $0.intent != "status_change" }
        let audits = merged.filter { $0.intent == "status_change" }
        VStack(alignment: .leading, spacing: 12) {
            if regular.isEmpty && audits.isEmpty {
                Text("No comments yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(regular) { comment in
                CommentRow(
                    comment: comment,
                    authorName: store.displayName(for: comment.createdByPubkey, in: comment.roomSlug),
                    isOptimistic: optimisticIds.contains(comment.id),
                    store: store,
                    fetcher: fetcher,
                    dispatchTraceOn: dispatchTraceOn
                )
            }
            if !audits.isEmpty {
                auditFold(audits: audits)
            }
        }
    }

    @ViewBuilder
    private func auditFold(audits: [StudioComment]) -> some View {
        DisclosureGroup(
            isExpanded: $auditFoldOpen
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(audits) { comment in
                    CommentRow(
                        comment: comment,
                        authorName: store.displayName(for: comment.createdByPubkey, in: comment.roomSlug),
                        isOptimistic: false,
                        store: store,
                        fetcher: fetcher,
                        dispatchTraceOn: dispatchTraceOn
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Status history (\(audits.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var optimisticCommentsForCard: [StudioComment] {
        store.optimisticComments.values.filter { c in
            c.roomSlug == card.roomSlug && c.targetEventId == card.eventId
        }
    }

}

// MARK: - FoldableBlock

/// Wraps a block view in a `DisclosureGroup` when the rendered content exceeds
/// 200pt of intrinsic height. Approximate height is measured once via
/// `GeometryReader`; subsequent renders fold by default. Per-block fold state.
struct FoldableBlock<Content: View>: View {
    let block: StudioBlock
    @ViewBuilder var content: () -> Content

    @State private var measuredHeight: CGFloat = 0
    @State private var folded: Bool = false

    /// Image and file blocks are interactive widgets — never auto-fold them,
    /// so the picture / download button is the first thing the reader sees.
    /// Long text/code/etc. still collapse past 200pt so the drawer stays
    /// scannable.
    private var isCompactWidget: Bool {
        switch block {
        case .image, .file: return true
        default: return false
        }
    }

    private var needsFold: Bool { !isCompactWidget && measuredHeight > 200 }

    var body: some View {
        Group {
            if needsFold {
                DisclosureGroup(
                    isExpanded: Binding(get: { !folded }, set: { folded = !$0 })
                ) {
                    content()
                } label: {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                content()
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: BlockHeightKey.self, value: geo.size.height)
                        }
                    )
                    .onPreferenceChange(BlockHeightKey.self) { h in
                        measuredHeight = h
                        if h > 200 && !isCompactWidget { folded = true }
                    }
            }
        }
    }

    private var label: String {
        switch block {
        case .text:    return "Text"
        case .code(let lang, _): return "Code (\(lang.isEmpty ? "plain" : lang))"
        case .link:    return "Link"
        case .field(let k, _):   return "Field: \(k)"
        case .image:   return "Image"
        case .file(let f):       return "File: \(f.filename)"
        case .unknown(let t, _): return "Unsupported: \(t)"
        }
    }
}

private struct BlockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - StudioBlockView (dispatch)

/// Thin dispatcher that picks the matching renderer view. Keeps the drawer
/// agnostic to the block taxonomy.
struct StudioBlockView: View {
    let block: StudioBlock
    let roomSlug: String
    let authorPubHex: String
    let fetcher: StudioImageFetcher
    let dispatchTraceOn: Bool
    /// True when the current user is the card's author — gates the file
    /// block's Re-share button so non-authors don't see an action they can't
    /// usefully perform.
    var canReshareFile: Bool = false
    /// Invoked when the user taps Re-share on a file block. Carries the
    /// originating block so the handler knows which file_key to replace.
    var onReshareFile: ((StudioFileBlock) -> Void)? = nil

    var body: some View {
        switch block {
        case .text(let body):
            TextBlockView(text: body)
        case .code(let lang, let body):
            CodeBlockView(language: lang, code: body)
        case .link(let href, let label):
            LinkBlockView(href: href, label: label)
        case .field(let k, let v):
            FieldBlockView(key: k, value: v)
        case .image(let img):
            ImageBlockView(
                block: img,
                room: roomSlug,
                authorPubHex: authorPubHex,
                fetcher: fetcher
            )
        case .file(let f):
            FileBlockView(
                block: f,
                room: roomSlug,
                authorPubHex: authorPubHex,
                canReshare: canReshareFile,
                onReshare: onReshareFile.map { cb in { cb(f) } }
            )
        case .unknown(let type, let raw):
            UnknownBlockView(type: type, raw: raw, dispatchTraceOn: dispatchTraceOn)
        }
    }
}

// MARK: - CommentRow

struct CommentRow: View {
    let comment: StudioComment
    let authorName: String
    var isOptimistic: Bool = false
    var store: StudioStore? = nil
    /// Image fetcher used to render image/file blocks attached to the comment.
    /// Nil-safe: blocks lacking media still render via StudioBlockView when a
    /// fetcher is unavailable (text/code/link/field), but image blocks need it.
    var fetcher: StudioImageFetcher? = nil
    var dispatchTraceOn: Bool = false

    private var isAudit: Bool { comment.intent == "status_change" }

    var body: some View {
        if isAudit {
            auditRow
        } else {
            normalRow
        }
    }

    @ViewBuilder
    private var normalRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let store {
                    StudioAvatarView(
                        store: store,
                        pubkeyHex: comment.createdByPubkey,
                        roomSlug: comment.roomSlug,
                        diameter: 16
                    )
                }
                Text(authorName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(StudioCardRow.relativeTime(from: comment.createdAtSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isOptimistic {
                    Spacer(minLength: 4)
                    ProgressView().controlSize(.small)
                }
            }
            if !comment.body.isEmpty {
                TextBlockView(text: comment.body)
            }
            if !comment.blocks.isEmpty, let fetcher {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(comment.blocks.enumerated()), id: \.offset) { _, block in
                        StudioBlockView(
                            block: block,
                            roomSlug: comment.roomSlug,
                            authorPubHex: comment.createdByPubkey,
                            fetcher: fetcher,
                            dispatchTraceOn: dispatchTraceOn
                        )
                    }
                }
            }
        }
        .opacity(isOptimistic ? 0.55 : 1.0)
    }

    /// Compact one-liner for status_change audit comments. Per design §15.6:
    /// "small icon + Sona: open → in_progress · just now".
    @ViewBuilder
    private var auditRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.swap")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(authorName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(":")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(auditBody)
                .font(.caption)
                .foregroundStyle(.primary)
            Text("·")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(StudioCardRow.relativeTime(from: comment.createdAtSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Strip the leading `status: ` prefix so the row reads as "open → done".
    /// Original body is `"status: open → in_progress"` — left intact for the
    /// raw audit feed; compacted here for the inline visual.
    private var auditBody: String {
        let body = comment.body
        if body.hasPrefix("status:") {
            return body.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
        }
        return body
    }
}

// MARK: - AssigneePickerPopover

/// Inline popover that lists every member of a room (avatar + display name)
/// with a Clear option at the bottom. Used by both the compose sheet's
/// assignee chip and the drawer's Reassign button.
struct AssigneePickerPopover: View {
    let store: StudioStore
    let roomSlug: String
    let currentAssignee: String?
    let onPick: (String?) -> Void

    @State private var query: String = ""

    private var members: [StudioMember] {
        let all = store.roomMembersList(for: roomSlug)
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter { m in
            store.displayName(for: m.pubkeyHex, in: roomSlug).lowercased().contains(needle) ||
            m.pubkeyHex.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search members", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(members, id: \.pubkeyHex) { m in
                        Button {
                            onPick(m.pubkeyHex)
                        } label: {
                            HStack(spacing: 8) {
                                StudioAvatarView(
                                    store: store,
                                    pubkeyHex: m.pubkeyHex,
                                    roomSlug: roomSlug,
                                    diameter: 20
                                )
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(store.displayName(for: m.pubkeyHex, in: roomSlug))
                                        .font(.system(size: 12, weight: .medium))
                                    Text(Hex.npubShort(m.pubkeyHex))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if currentAssignee?.lowercased() == m.pubkeyHex.lowercased() {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)

            Divider()
            Button {
                onPick(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle")
                    Text("Clear assignment")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        .frame(width: 260)
    }
}
