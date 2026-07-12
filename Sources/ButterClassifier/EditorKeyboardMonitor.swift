import SwiftUI

/// Ensures the shared EditorKeyboardRouter installs its window-level monitor.
struct EditorKeyboardMonitor: View {
    let router: EditorKeyboardRouter

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
    }
}
