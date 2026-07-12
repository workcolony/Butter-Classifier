import AppKit
import SwiftUI

/// Captures scroll-wheel and trackpad gestures over the waveform.
/// Trackpad: two-finger sideways pan, pinch or vertical scroll to zoom.
/// Mouse: Shift+scroll pans, Option+scroll zooms (anchored to cursor).
struct WaveformWheelHandler: NSViewRepresentable {
    var canPanHorizontally: Bool = true
    var onHorizontalScroll: ((CGFloat) -> Void)?
    /// (zoom delta, mouse X in view coordinates)
    var onZoom: ((CGFloat, CGFloat) -> Void)?

    func makeNSView(context: Context) -> WaveformWheelCaptureView {
        let view = WaveformWheelCaptureView()
        view.canPanHorizontally = canPanHorizontally
        view.onHorizontalScroll = onHorizontalScroll
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: WaveformWheelCaptureView, context: Context) {
        view.canPanHorizontally = canPanHorizontally
        view.onHorizontalScroll = onHorizontalScroll
        view.onZoom = onZoom
    }
}

final class WaveformWheelCaptureView: NSView {
    var canPanHorizontally = true
    var onHorizontalScroll: ((CGFloat) -> Void)?
    var onZoom: ((CGFloat, CGFloat) -> Void)?
    private var scrollMonitor: Any?
    private var magnifyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitors()
        guard window != nil else { return }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            guard self.containsMouse(event: event) else { return event }
            return self.handleScrollWheel(event) ? nil : event
        }

        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self else { return event }
            guard self.containsMouse(event: event) else { return event }
            return self.handleMagnify(event) ? nil : event
        }
    }

    deinit {
        removeMonitors()
    }

    private func removeMonitors() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
            self.magnifyMonitor = nil
        }
    }

    /// Returns true when the event was handled and should not propagate.
    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        guard deltaX != 0 || deltaY != 0 else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let zoomModifiers: NSEvent.ModifierFlags = [.option, .command]
        if !flags.intersection(zoomModifiers).isEmpty {
            let raw = primaryScrollDelta(from: event)
            guard raw != 0 else { return false }
            onZoom?(-raw, mouseX(in: event))
            return true
        }

        if flags.contains(.shift) {
            let raw = horizontalScrollDelta(from: event)
            guard raw != 0, canPanHorizontally else { return false }
            onHorizontalScroll?(Self.accelerated(raw, event: event))
            return true
        }

        // Trackpad: natural two-finger horizontal swipe pans when zoomed.
        if event.hasPreciseScrollingDeltas, abs(deltaX) > abs(deltaY) * 0.35, deltaX != 0 {
            guard canPanHorizontally else { return false }
            onHorizontalScroll?(Self.accelerated(deltaX, event: event))
            return true
        }

        // Trackpad: vertical two-finger scroll zooms (pinch is handled separately).
        if event.hasPreciseScrollingDeltas, abs(deltaY) >= abs(deltaX), deltaY != 0 {
            onZoom?(-deltaY, mouseX(in: event))
            return true
        }

        return false
    }

    /// Returns true when the event was handled and should not propagate.
    private func handleMagnify(_ event: NSEvent) -> Bool {
        let delta = event.magnification
        guard abs(delta) > 0.0001 else { return false }
        // Positive magnification zooms in; scale to match scroll-wheel zoom feel.
        onZoom?(delta * 18, mouseX(in: event))
        return true
    }

    private func containsMouse(event: NSEvent) -> Bool {
        guard window != nil else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    private func mouseX(in event: NSEvent) -> CGFloat {
        convert(event.locationInWindow, from: nil).x
    }

    private func primaryScrollDelta(from event: NSEvent) -> CGFloat {
        if event.scrollingDeltaY != 0 { return event.scrollingDeltaY }
        return event.scrollingDeltaX
    }

    private func horizontalScrollDelta(from event: NSEvent) -> CGFloat {
        if event.scrollingDeltaX != 0 { return event.scrollingDeltaX }
        return event.scrollingDeltaY
    }

    /// Boost wheel deltas so horizontal pan feels responsive.
    static func accelerated(_ delta: CGFloat, event: NSEvent) -> CGFloat {
        let sign: CGFloat = delta >= 0 ? 1 : -1
        let magnitude = abs(delta)
        let base: CGFloat = event.hasPreciseScrollingDeltas ? 2.2 : 3.5
        let curved = pow(magnitude, 1.12)
        return sign * curved * base
    }
}
