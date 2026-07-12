import Foundation
import SwiftUI

/// Tracks shift+Tab / shift+arrow range growth. Reference type so keyboard
/// handlers always see the latest anchor even when invoked from NSViewRepresentable.
@MainActor
final class ShiftSelectionSession {
    private(set) var anchor: Double?
    private(set) var movingEnd: Double?
    private var extensionDirection: Int?

    var isActive: Bool { anchor != nil }

    func reset() {
        anchor = nil
        movingEnd = nil
        extensionDirection = nil
    }

    func extendToOnset(
        direction: Int,
        playhead: Double,
        existing: ClosedRange<Double>?,
        onsets: [Double],
        duration: Double
    ) -> ClosedRange<Double>? {
        let forward = direction > 0
        if extensionDirection != direction {
            reset()
            extensionDirection = direction
        }
        if anchor == nil {
            if let sel = existing {
                anchor = forward ? sel.lowerBound : sel.upperBound
                movingEnd = forward ? sel.upperBound : sel.lowerBound
            } else {
                anchor = playhead
                movingEnd = playhead
            }
        }
        guard let fixedAnchor = anchor, let extendFrom = movingEnd else { return nil }

        if forward {
            guard let target = Self.onsetTime(direction: 1, from: extendFrom, onsets: onsets) else { return nil }
            movingEnd = target
            return Self.makeSelection(from: fixedAnchor, to: target)
        }
        guard let target = Self.onsetTime(direction: -1, from: extendFrom, onsets: onsets) else { return nil }
        movingEnd = target
        return Self.makeSelection(from: target, to: fixedAnchor)
    }

    func extendByTime(
        direction: Int,
        playhead: Double,
        existing: ClosedRange<Double>?,
        duration: Double,
        step: Double
    ) -> ClosedRange<Double>? {
        let forward = direction > 0
        if extensionDirection != direction {
            reset()
            extensionDirection = direction
        }
        if anchor == nil {
            if let sel = existing {
                anchor = forward ? sel.lowerBound : sel.upperBound
                movingEnd = forward ? sel.upperBound : sel.lowerBound
            } else {
                anchor = playhead
                movingEnd = playhead
            }
        }
        guard let fixedAnchor = anchor else { return nil }

        if forward {
            let currentEnd = movingEnd ?? fixedAnchor
            let target = min(currentEnd + step, duration)
            movingEnd = target
            return Self.makeSelection(from: fixedAnchor, to: target)
        }
        let currentStart = movingEnd ?? fixedAnchor
        let target = max(currentStart - step, 0)
        movingEnd = target
        return Self.makeSelection(from: target, to: fixedAnchor)
    }

    static func collapseSelectionEdge(
        _ selection: ClosedRange<Double>?,
        direction: Int
    ) -> Double? {
        guard let selection else { return nil }
        return direction > 0 ? selection.upperBound : selection.lowerBound
    }

    static func onsetTime(direction: Int, from time: Double, onsets: [Double]) -> Double? {
        let sorted = onsets.sorted()
        guard !sorted.isEmpty else { return nil }
        let epsilon = 0.002
        if direction > 0 {
            return sorted.first(where: { $0 > time + epsilon }) ?? sorted.last
        }
        return sorted.last(where: { $0 < time - epsilon }) ?? sorted.first
    }

    static func makeSelection(from start: Double, to end: Double) -> ClosedRange<Double>? {
        let lo = min(start, end)
        let hi = max(start, end)
        guard hi - lo > 0.001 else { return nil }
        return lo...hi
    }
}

@MainActor
final class EditorKeyboardHandler {
    let shiftSession = ShiftSelectionSession()

    var selection: Binding<ClosedRange<Double>?>?
    var playhead: (() -> Double)?
    var duration: (() -> Double)?
    var onsets: (() -> [Double])?
    var seek: ((Double) -> Void)?
    var ensureLoaded: (() -> Void)?

    func handle(_ event: EditorKeyEvent) {
        ensureLoaded?()
        guard let duration = duration?(), duration > 0 else { return }
        let playhead = playhead?() ?? 0
        let onsets = onsets?() ?? []
        let nudgeStep = 8.0

        switch event.key {
        case .tab:
            if event.shift {
                if let sel = shiftSession.extendToOnset(
                    direction: event.direction,
                    playhead: playhead,
                    existing: selection?.wrappedValue,
                    onsets: onsets,
                    duration: duration
                ) {
                    selection?.wrappedValue = sel
                    seek?(event.direction > 0 ? sel.upperBound : sel.lowerBound)
                }
            } else {
                shiftSession.reset()
                if let edge = ShiftSelectionSession.collapseSelectionEdge(
                    selection?.wrappedValue,
                    direction: event.direction
                ) {
                    selection?.wrappedValue = nil
                    seek?(edge)
                } else if let target = ShiftSelectionSession.onsetTime(
                    direction: event.direction,
                    from: playhead,
                    onsets: onsets
                ) {
                    seek?(target)
                }
            }
        case .arrow:
            if event.shift {
                if let sel = shiftSession.extendByTime(
                    direction: event.direction,
                    playhead: playhead,
                    existing: selection?.wrappedValue,
                    duration: duration,
                    step: nudgeStep
                ) {
                    selection?.wrappedValue = sel
                    seek?(event.direction > 0 ? sel.upperBound : sel.lowerBound)
                }
            } else {
                shiftSession.reset()
                if let edge = ShiftSelectionSession.collapseSelectionEdge(
                    selection?.wrappedValue,
                    direction: event.direction
                ) {
                    selection?.wrappedValue = nil
                    seek?(edge)
                } else {
                    let target = min(max(0, playhead + Double(event.direction) * nudgeStep), duration)
                    seek?(target)
                }
            }
        case .returnKey:
            shiftSession.reset()
            seek?(event.direction < 0 ? 0 : duration)
        case .selectionBoundary:
            guard let sel = selection?.wrappedValue, sel.upperBound > sel.lowerBound else { return }
            seek?(event.direction < 0 ? sel.lowerBound : sel.upperBound)
        }
    }
}
