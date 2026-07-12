import AppKit
import SwiftUI

/// macOS-native horizontal resize drag handle with 1:1 pointer tracking.
struct HorizontalPaneResizeHandle: NSViewRepresentable {
    var onResizeDelta: (CGFloat) -> Void
    var onResizeEnded: () -> Void

    func makeNSView(context: Context) -> HorizontalResizeDragView {
        let view = HorizontalResizeDragView()
        view.onResizeDelta = onResizeDelta
        view.onResizeEnded = onResizeEnded
        return view
    }

    func updateNSView(_ view: HorizontalResizeDragView, context: Context) {
        view.onResizeDelta = onResizeDelta
        view.onResizeEnded = onResizeEnded
    }
}

final class HorizontalResizeDragView: NSView {
    var onResizeDelta: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    private var lastX: CGFloat?

    override var isOpaque: Bool { false }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastX else { return }
        let x = event.locationInWindow.x
        let delta = lastX - x
        if abs(delta) > 0.01 {
            onResizeDelta?(delta)
        }
        self.lastX = x
    }

    override func mouseUp(with event: NSEvent) {
        lastX = nil
        onResizeEnded?()
    }
}
