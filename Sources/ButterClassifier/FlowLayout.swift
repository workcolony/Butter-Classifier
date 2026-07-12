import SwiftUI

/// Left-to-right flow layout that wraps items onto additional rows instead of compressing them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        guard let last = rows.last else { return .zero }
        return CGSize(width: proposal.width ?? last.contentWidth, height: last.maxY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        for row in rows {
            for item in row.items {
                item.view.place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: .unspecified
                )
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var maxY: CGFloat
        var contentWidth: CGFloat
        var items: [(view: LayoutSubview, x: CGFloat)]
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxW = proposal.width ?? .infinity
        var rows: [Row] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var items: [(LayoutSubview, CGFloat)] = []

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxW, !items.isEmpty {
                rows.append(Row(
                    y: y,
                    maxY: y + rowH,
                    contentWidth: max(0, x - spacing),
                    items: items.map { ($0.0, $0.1) }
                ))
                y += rowH + rowSpacing
                x = 0
                rowH = 0
                items = []
            }
            items.append((sub, x))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }

        if !items.isEmpty {
            rows.append(Row(
                y: y,
                maxY: y + rowH,
                contentWidth: max(0, x - spacing),
                items: items.map { ($0.0, $0.1) }
            ))
        }

        return rows
    }
}

extension View {
    /// Keep toolbar clusters at their natural size so wrapping happens before compression.
    func toolbarCluster() -> some View {
        fixedSize(horizontal: true, vertical: false)
    }
}
