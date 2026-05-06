import SwiftUI

struct SearchOverlay: View {
    @ObservedObject var vm: SearchViewModel
    var onWiki: (RecallWikiPageDTO) -> Void

    @State private var memoryDetail: RecallMemoryDTO?
    @State private var entityDetail: RecallEntityDTO?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { vm.dismiss() }

            VStack(spacing: 0) {
                header

                Divider()

                Group {
                    if vm.isLoading && allEmpty {
                        loadingView
                    } else if let err = vm.errorMessage {
                        errorView(err)
                    } else if allEmpty {
                        emptyView
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if !vm.memories.isEmpty { memoriesSection }
                                if !vm.entities.isEmpty { entitiesSection }
                                if !vm.wikiPages.isEmpty { wikiSection }
                                if vm.truncated {
                                    Text("More results were truncated for budget.")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
            .frame(width: 600)
            .frame(maxHeight: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
            .onExitCommand { vm.dismiss() }
        }
        .sheet(item: $memoryDetail) { mem in
            MemoryDetailSheet(memory: mem) { memoryDetail = nil }
        }
        .sheet(item: $entityDetail) { ent in
            EntityDetailSheet(entity: ent) { entityDetail = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Results for")
                .foregroundStyle(.secondary)
            Text("“\(vm.lastSubmittedQuery)”")
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if vm.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                vm.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - States

    private var allEmpty: Bool {
        vm.memories.isEmpty && vm.entities.isEmpty && vm.wikiPages.isEmpty
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Recalling…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(msg)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Retry") {
                vm.submit()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No results for “\(vm.lastSubmittedQuery)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Try a different phrase or check spelling.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Sections

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Memories", count: vm.memories.count, icon: "brain.head.profile")
            VStack(spacing: 4) {
                ForEach(vm.memories) { mem in
                    Button {
                        memoryDetail = mem
                    } label: {
                        memoryRow(mem)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var entitiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Entities", count: vm.entities.count, icon: "tag.fill")
            VStack(spacing: 4) {
                ForEach(vm.entities) { ent in
                    Button {
                        entityDetail = ent
                    } label: {
                        entityRow(ent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var wikiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Wiki Pages", count: vm.wikiPages.count, icon: "book.fill")
            VStack(spacing: 4) {
                ForEach(vm.wikiPages) { page in
                    Button {
                        onWiki(page)
                    } label: {
                        wikiRow(page)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("(\(count))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Rows

    private func memoryRow(_ mem: RecallMemoryDTO) -> some View {
        let snippet: String = {
            if let l0 = mem.l0, !l0.isEmpty { return l0 }
            if let c = mem.content, !c.isEmpty { return String(c.prefix(160)) }
            return mem.type
        }()
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(mem.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let s = mem.source, !s.isEmpty {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(s)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(formatDate(mem.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func entityRow(_ ent: RecallEntityDTO) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(ent.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let desc = ent.description, !desc.isEmpty {
                    Text(String(desc.prefix(120)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func wikiRow(_ page: RecallWikiPageDTO) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(page.slug)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !page.snippet.isEmpty {
                    Text(String(page.snippet.prefix(160)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func formatDate(_ epochMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(epochMs) / 1000)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Detail sheets (v0 — full deep-nav deferred)

private struct MemoryDetailSheet: View {
    let memory: RecallMemoryDTO
    var onClose: () -> Void

    @State private var copiedLabel: String? = nil

    private var fullContent: String {
        memory.content ?? memory.l1 ?? memory.l0 ?? ""
    }

    /// Natural-language instruction for a Sona session to fetch THIS memory.
    private var recallCommand: String {
        "Recall memory \(memory._id)"
    }

    private func copy(_ string: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        copiedLabel = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedLabel == label { copiedLabel = nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(memory.type, systemImage: "brain.head.profile")
                    .font(.headline)
                if let copiedLabel {
                    Text("Copied \(copiedLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button {
                    copy(fullContent, label: "memory")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy memory content")
                Button {
                    copy(recallCommand, label: "recall")
                } label: {
                    Label("Copy recall", systemImage: "text.viewfinder")
                }
                .help("Copy a recall instruction (\"Recall memory <id>\") for pasting into a Sona session")
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let l0 = memory.l0, !l0.isEmpty {
                        Text(l0)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(fullContent)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let tags = memory.tags, !tags.isEmpty {
                        Text(tags.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text("ID: \(memory._id)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .animation(.easeInOut(duration: 0.15), value: copiedLabel)
    }
}

private struct EntityDetailSheet: View {
    let entity: RecallEntityDTO
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(entity.name, systemImage: "tag.fill")
                    .font(.headline)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entity.type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let desc = entity.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("ID: \(entity._id)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}
