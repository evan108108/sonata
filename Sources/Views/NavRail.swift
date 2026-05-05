import SwiftUI

struct NavRailItem: Identifiable, Equatable {
    let tab: SonataTab
    let label: String
    let systemImage: String
    var id: SonataTab { tab }
}

struct NavRail: View {
    @Binding var selected: SonataTab
    let items: [NavRailItem]

    private let railWidth: CGFloat = 80
    private let cellHeight: CGFloat = 64
    private let moreCellHeight: CGFloat = 64

    @State private var showOverflow = false

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = proxy.size.height
            let layout = computeLayout(availableHeight: availableHeight)

            VStack(spacing: 0) {
                if layout.scrollFallback {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                cell(for: item)
                            }
                        }
                    }
                } else {
                    ForEach(layout.visibleItems) { item in
                        cell(for: item)
                    }
                    if !layout.overflowItems.isEmpty {
                        moreCell(overflowItems: layout.overflowItems)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(width: railWidth, height: availableHeight, alignment: .top)
        }
        .frame(width: railWidth)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }

    // MARK: - Layout

    private struct Layout {
        let visibleItems: [NavRailItem]
        let overflowItems: [NavRailItem]
        let scrollFallback: Bool
    }

    private func computeLayout(availableHeight: CGFloat) -> Layout {
        let total = items.count
        let allFitCount = Int(floor(availableHeight / cellHeight))

        if allFitCount >= total {
            return Layout(visibleItems: items, overflowItems: [], scrollFallback: false)
        }

        let visibleCount = Int(floor((availableHeight - moreCellHeight) / cellHeight))
        if visibleCount < 1 {
            return Layout(visibleItems: items, overflowItems: [], scrollFallback: true)
        }

        let visibleSlice = Array(items.prefix(visibleCount))
        let overflow = Array(items.suffix(from: visibleCount))
        return Layout(visibleItems: visibleSlice, overflowItems: overflow, scrollFallback: false)
    }

    // MARK: - Cells

    private func cell(for item: NavRailItem) -> some View {
        let isSelected = selected == item.tab
        return Button {
            selected = item.tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 20, weight: .regular))
                Text(item.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: railWidth, height: cellHeight)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func moreCell(overflowItems: [NavRailItem]) -> some View {
        let containsSelected = overflowItems.contains(where: { $0.tab == selected })
        return Button {
            showOverflow = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .regular))
                Text("More")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: railWidth, height: moreCellHeight)
            .foregroundStyle(containsSelected ? Color.accentColor : Color.secondary)
            .background(
                containsSelected
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .popover(isPresented: $showOverflow, arrowEdge: .trailing) {
            VStack(spacing: 0) {
                ForEach(overflowItems) { item in
                    Button {
                        selected = item.tab
                        showOverflow = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.systemImage)
                                .frame(width: 20)
                            Text(item.label)
                                .font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minWidth: 160, alignment: .leading)
                        .foregroundStyle(selected == item.tab ? Color.accentColor : Color.primary)
                        .background(selected == item.tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
            .padding(.vertical, 4)
        }
    }
}
