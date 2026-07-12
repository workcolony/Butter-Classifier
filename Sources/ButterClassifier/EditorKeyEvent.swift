import Foundation

/// Keyboard events routed to the sample editor from the detail pane.
struct EditorKeyEvent {
    enum Key: Equatable {
        case arrow
        case tab
        /// Return — jump playhead to file start (↓) or end (↑).
        case returnKey
        /// ⌘↑/⌘↓ — jump playhead to selection end/start without changing the range.
        case selectionBoundary
    }

    let key: Key
    let direction: Int
    let shift: Bool
    let option: Bool
}
