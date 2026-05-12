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

    private var canMutate: Bool {
        !card.createdByPubkey.isEmpty &&
            card.createdByPubkey.lowercased() == store.currentPubkeyHex.lowercased() &&
            !card.dTag.isEmpty
    }

    private var canDelete: Bool { canMutate }
    private var canEdit: Bool { canMutate }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                        dispatchTraceOn: dispatchTraceOn
                    )
                }
            }
        }
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
        if merged.isEmpty {
            Text("No comments yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(merged) { comment in
                    CommentRow(
                        comment: comment,
                        authorName: store.displayName(for: comment.createdByPubkey),
                        isOptimistic: optimisticIds.contains(comment.id)
                    )
                }
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

    /// Image blocks are visual — never auto-fold them, so the picture is
    /// the first thing the reader sees. Long text/code/etc. still collapse
    /// past 200pt so the drawer stays scannable.
    private var isImage: Bool {
        if case .image = block { return true }
        return false
    }

    private var needsFold: Bool { !isImage && measuredHeight > 200 }

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
                        if h > 200 && !isImage { folded = true }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
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
            TextBlockView(text: comment.body)
        }
        .opacity(isOptimistic ? 0.55 : 1.0)
    }
}
