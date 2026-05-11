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

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    blockList
                    Divider()
                    commentThread
                }
                .padding(16)
            }
            Divider()
            composeStub
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
        let comments = store.comments(forCard: card.eventId)
            .sorted(by: { $0.createdAtSeconds < $1.createdAtSeconds })
        if comments.isEmpty {
            Text("No comments yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(comments) { comment in
                    CommentRow(
                        comment: comment,
                        authorName: store.displayName(for: comment.createdByPubkey)
                    )
                }
            }
        }
    }

    // MARK: - Compose stub (W6 ships StudioCommentCompose)

    @ViewBuilder
    private var composeStub: some View {
        HStack(spacing: 8) {
            TextField("Reply…", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
            Button {
                // W6: StudioCommentCompose.submit
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderless)
            .disabled(true)
        }
        .opacity(0.55)
        .help("Comment compose ships in W6")
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

    private var needsFold: Bool { measuredHeight > 200 }

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
                        if h > 200 { folded = true }
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
            }
            TextBlockView(text: comment.body)
        }
    }
}
