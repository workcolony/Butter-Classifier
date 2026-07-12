import AppKit
import SwiftUI

/// macOS-native vertical resize drag handle with 1:1 pointer tracking.
struct VerticalPaneResizeHandle: NSViewRepresentable {
    var onResizeDelta: (CGFloat) -> Void
    var onResizeEnded: () -> Void

    func makeNSView(context: Context) -> ResizeDragView {
        let view = ResizeDragView()
        view.onResizeDelta = onResizeDelta
        view.onResizeEnded = onResizeEnded
        return view
    }

    func updateNSView(_ view: ResizeDragView, context: Context) {
        view.onResizeDelta = onResizeDelta
        view.onResizeEnded = onResizeEnded
    }
}

final class ResizeDragView: NSView {
    var onResizeDelta: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    private var lastY: CGFloat?

    override var isOpaque: Bool { false }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastY else { return }
        let y = event.locationInWindow.y
        // Window coords: Y increases upward — dragging down shrinks Y, so invert for height.
        let delta = lastY - y
        if abs(delta) > 0.01 {
            onResizeDelta?(delta)
        }
        self.lastY = y
    }

    override func mouseUp(with event: NSEvent) {
        lastY = nil
        onResizeEnded?()
    }
}
