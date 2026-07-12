import AppKit
import SwiftUI

/// Scrolls the underlying AppKit table so keyboard-focused rows stay visible.
struct SampleFileTableScrollHelper: NSViewRepresentable {
    let rowIndex: Int?
    let expectedRowCount: Int
    let scrollToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TableScrollAnchorView {
        let view = TableScrollAnchorView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: TableScrollAnchorView, context: Context) {
        nsView.rowIndex = rowIndex
        nsView.expectedRowCount = expectedRowCount
        nsView.scrollToken = scrollToken
        nsView.coordinator = context.coordinator
        nsView.scheduleScroll()
    }

    final class Coordinator {
        weak var tableView: NSTableView?
    }
}

/// Hidden anchor view that discovers the sample `NSTableView` and scrolls it.
final class TableScrollAnchorView: NSView {
    weak var coordinator: SampleFileTableScrollHelper.Coordinator?
    var rowIndex: Int?
    var expectedRowCount = 0
    var scrollToken = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleScroll()
    }

    func scheduleScroll() {
        guard rowIndex != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.performScroll()
        }
    }

    private func performScroll() {
        guard let rowIndex, rowIndex >= 0 else { return }

        let tableView = coordinator?.tableView ?? findSampleTableView()
        coordinator?.tableView = tableView
        guard let tableView else { return }
        guard rowIndex < tableView.numberOfRows else { return }

        tableView.scrollRowToVisible(rowIndex)
        if let scrollView = tableView.enclosingScrollView {
            let rowRect = tableView.rect(ofRow: rowIndex)
            if !scrollView.documentVisibleRect.insetBy(dx: 0, dy: -6).intersects(rowRect) {
                scrollView.scrollToVisible(rowRect.insetBy(dx: 0, dy: -6))
            }
        }
    }

    private func findSampleTableView() -> NSTableView? {
        if let table = nearestTableView(in: superview), table.numberOfRows == expectedRowCount {
            return table
        }
        guard let root = window?.contentView else { return nil }
        return Self.findBestTable(in: root, expectedRowCount: expectedRowCount)
    }

    private func nearestTableView(in root: NSView?) -> NSTableView? {
        var view: NSView? = root
        while let current = view {
            if let table = current as? NSTableView {
                return table
            }
            for sibling in current.superview?.subviews ?? [] where sibling !== current {
                if let table = Self.findBestTable(in: sibling, expectedRowCount: expectedRowCount) {
                    return table
                }
            }
            view = current.superview
        }
        return nil
    }

    private static func findBestTable(in view: NSView, expectedRowCount: Int) -> NSTableView? {
        var match: NSTableView?
        var largest: NSTableView?

        func visit(_ node: NSView) {
            if let table = node as? NSTableView {
                if table.numberOfRows == expectedRowCount {
                    match = table
                } else if largest == nil || table.numberOfRows > (largest?.numberOfRows ?? 0) {
                    largest = table
                }
            }
            for subview in node.subviews {
                visit(subview)
            }
        }

        visit(view)
        return match ?? largest
    }
}
