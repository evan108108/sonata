import SwiftUI

struct NavRailItem: Identifiable, Equatable {
    let tab: SonataTab
    let label: String
    let systemImage: String
    var badge: Int = 0
    /// When true, badge renders with a trailing "!" to signal "needs
    /// attention" (e.g. failed plugins). Cosmetic only — count stays in
    /// `badge`; the suffix lives in NavRailCell.
    var badgeIsAlert: Bool = false
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
        NavRailCell(
            item: item,
            isSelected: selected == item.tab,
            railWidth: railWidth,
            cellHeight: cellHeight
        ) {
            selected = item.tab
        }
    }

    private func moreCell(overflowItems: [NavRailItem]) -> some View {
        let containsSelected = overflowItems.contains(where: { $0.tab == selected })
        return NavRailMoreCell(
            isActive: containsSelected,
            railWidth: railWidth,
            cellHeight: moreCellHeight
        ) {
            showOverflow = true
        }
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

private struct NavRailCell: View {
    let item: NavRailItem
    let isSelected: Bool
    let railWidth: CGFloat
    let cellHeight: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 20, weight: .regular))
                    if item.badge > 0 {
                        let count = item.badge > 99 ? "99+" : "\(item.badge)"
                        let label = item.badgeIsAlert ? "\(count)!" : count
                        Text(label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            // Green for informational counts ("good things
                            // happening" — unread, busy, active); red when
                            // badgeIsAlert flags an actual problem state
                            // (e.g. failed plugins). Keeps the alarm color
                            // reserved for alarms.
                            .background(item.badgeIsAlert ? Color.red : Color.green, in: Capsule())
                            .offset(x: 10, y: -6)
                    }
                }
                Text(item.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: railWidth, height: cellHeight)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .background(backgroundColor)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
}

private struct NavRailMoreCell: View {
    let isActive: Bool
    let railWidth: CGFloat
    let cellHeight: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .regular))
                Text("More")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: railWidth, height: cellHeight)
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .background(backgroundColor)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var backgroundColor: Color {
        if isActive {
            return Color.accentColor.opacity(0.15)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
}
