import SwiftUI
import SwiftData

/// Arrow-key navigation through an ordered list of identifiable items.
enum SampleListNavigation {
    static func move<ID: Hashable>(
        in items: [ID],
        current: ID?,
        by delta: Int
    ) -> ID? {
        guard !items.isEmpty else { return nil }
        let index: Int
        if let current, let found = items.firstIndex(of: current) {
            index = found
        } else {
            return items[delta >= 0 ? 0 : items.count - 1]
        }
        let next = max(0, min(items.count - 1, index + delta))
        return items[next]
    }

    /// Finder-style contiguous range between a fixed anchor and a moving end.
    static func rangedSelection<ID: Hashable>(
        in items: [ID],
        anchor: ID,
        end: ID
    ) -> Set<ID> {
        guard let anchorIndex = items.firstIndex(of: anchor),
              let endIndex = items.firstIndex(of: end)
        else { return [end] }
        let lo = min(anchorIndex, endIndex)
        let hi = max(anchorIndex, endIndex)
        return Set(items[lo...hi])
    }

    /// Primary row for keyboard navigation — prefers keyboard focus, else last selected in list order.
    static func primaryRow<ID: Hashable>(
        in items: [ID],
        focus: ID?,
        selection: Set<ID>
    ) -> ID? {
        if let focus { return focus }
        let ordered = items.filter { selection.contains($0) }
        return ordered.last ?? items.first
    }
}

extension View {
    /// Standard sample-list shortcuts: arrows move, space plays, return adopts.
    /// `horizontalEnabled` — when false, left/right are left to the waveform editor.
    /// Shift+arrow is handled at window level via `EditorKeyboardRouter` for the main sample table.
    func sampleListKeyboard(
        enabled: Bool = true,
        horizontalEnabled: Bool = true,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        onAdopt: (() -> Void)? = nil,
        onEscape: (() -> Bool)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        self
            .onKeyPress(.leftArrow) {
                guard enabled, horizontalEnabled else { return .ignored }
                onPrevious()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard enabled, horizontalEnabled else { return .ignored }
                onNext()
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard enabled else { return .ignored }
                onPrevious()
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard enabled else { return .ignored }
                onNext()
                return .handled
            }
            .onKeyPress(.space) {
                guard enabled else { return .ignored }
                onPlay()
                return .handled
            }
            .onKeyPress(.return) {
                guard enabled, let onAdopt else { return .ignored }
                onAdopt()
                return .handled
            }
            .onKeyPress(.escape) {
                if let onEscape, onEscape() { return .handled }
                guard enabled, let onDismiss else { return .ignored }
                onDismiss()
                return .handled
            }
    }
}
