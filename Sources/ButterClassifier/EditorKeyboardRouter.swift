import AppKit
import SwiftUI

/// Window-level keyboard routing for the sample editor. A single NSEvent monitor
/// intercepts Tab/arrows before AppKit focus navigation (search field, table, etc.).
@MainActor
final class EditorKeyboardRouter {
    struct Registration {
        let handler: EditorKeyboardHandler
        let selection: Binding<ClosedRange<Double>?>
        let playhead: () -> Double
        let duration: () -> Double
        let onsets: () -> [Double]
        let seek: (Double) -> Void
        let ensureLoaded: () -> Void
        let onUndo: (() -> Void)?
        let onRedo: (() -> Void)?
    }

    struct ListRegistration {
        let isEnabled: () -> Bool
        let onPrevious: (_ shift: Bool) -> Void
        let onNext: (_ shift: Bool) -> Void
    }

    var isEnabled = false
    private var registration: Registration?
    private var listRegistration: ListRegistration?
    private static var monitor: Any?
    private static weak var activeRouter: EditorKeyboardRouter?

    init() {
        Self.installMonitorIfNeeded(router: self)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            Self.activeRouter = self
        } else if Self.activeRouter === self {
            Self.activeRouter = nil
        }
    }

    func setRegistration(_ registration: Registration?) {
        self.registration = registration
        Self.activeRouter = self
    }

    func setListRegistration(_ registration: ListRegistration?) {
        listRegistration = registration
        Self.activeRouter = self
    }

    func unregister(handler: EditorKeyboardHandler) {
        guard registration?.handler === handler else { return }
        registration = nil
        if Self.activeRouter === self, !isEnabled {
            Self.activeRouter = nil
        }
    }

    private static func installMonitorIfNeeded(router: EditorKeyboardRouter) {
        guard monitor == nil else { return }
        activeRouter = router
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let activeRouter else { return event }
            return MainActor.assumeIsolated {
                activeRouter.process(event)
            }
        }
    }

    private func process(_ event: NSEvent) -> NSEvent? {
        guard !Self.isTyping(in: event.window) else { return event }

        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        let command = event.modifierFlags.contains(.command)

        if let list = listRegistration, list.isEnabled() {
            switch event.keyCode {
            case 126 where !command:
                list.onPrevious(shift)
                return nil
            case 125 where !command:
                list.onNext(shift)
                return nil
            case 123 where !isEnabled:
                list.onPrevious(shift)
                return nil
            case 124 where !isEnabled:
                list.onNext(shift)
                return nil
            default:
                break
            }
        }

        guard isEnabled, let reg = registration else { return event }

        switch event.keyCode {
        case 6 where command:
            if shift {
                guard reg.onRedo != nil else { return event }
                reg.onRedo?()
            } else {
                guard reg.onUndo != nil else { return event }
                reg.onUndo?()
            }
            return nil
        case 48:
            dispatch(EditorKeyEvent(
                key: .tab,
                direction: option ? -1 : 1,
                shift: shift,
                option: option
            ), registration: reg)
            return nil
        case 36:
            guard !shift else { return event }
            dispatch(EditorKeyEvent(
                key: .returnKey,
                direction: command ? 1 : -1,
                shift: false,
                option: option
            ), registration: reg)
            return nil
        case 123:
            dispatch(EditorKeyEvent(key: .arrow, direction: -1, shift: shift, option: option), registration: reg)
            return nil
        case 124:
            dispatch(EditorKeyEvent(key: .arrow, direction: 1, shift: shift, option: option), registration: reg)
            return nil
        case 125 where command:
            guard let sel = reg.selection.wrappedValue, sel.upperBound > sel.lowerBound else { return event }
            dispatch(EditorKeyEvent(key: .selectionBoundary, direction: -1, shift: shift, option: option), registration: reg)
            return nil
        case 126 where command:
            guard let sel = reg.selection.wrappedValue, sel.upperBound > sel.lowerBound else { return event }
            dispatch(EditorKeyEvent(key: .selectionBoundary, direction: 1, shift: shift, option: option), registration: reg)
            return nil
        default:
            return event
        }
    }

    private func dispatch(_ event: EditorKeyEvent, registration reg: Registration) {
        reg.handler.selection = reg.selection
        reg.handler.playhead = reg.playhead
        reg.handler.duration = reg.duration
        reg.handler.onsets = reg.onsets
        reg.handler.seek = reg.seek
        reg.handler.ensureLoaded = reg.ensureLoaded
        reg.handler.handle(event)
    }

    private static func isTyping(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if responder is NSTextField { return true }
        if responder is NSSearchField { return true }
        // SwiftUI searchable toolbar field
        let name = String(describing: type(of: responder))
        if name.contains("SearchField") || name.contains("Search") && name.contains("Field") {
            return true
        }
        return false
    }
}

/// Keeps sample-list arrow shortcuts active even when the table owns keyboard focus.
struct SampleListKeyboardRegistrationView: View {
    let router: EditorKeyboardRouter
    let isEnabled: () -> Bool
    let onPrevious: (_ shift: Bool) -> Void
    let onNext: (_ shift: Bool) -> Void
    var registrationKey: String = ""

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { publish() }
            .onChange(of: registrationKey) { publish() }
            .onDisappear { router.setListRegistration(nil) }
    }

    private func publish() {
        router.setListRegistration(EditorKeyboardRouter.ListRegistration(
            isEnabled: isEnabled,
            onPrevious: onPrevious,
            onNext: onNext
        ))
    }
}

/// Keeps the router registration in sync with the current DetailPane state.
struct EditorKeyboardRegistrationView: View {
    let router: EditorKeyboardRouter
    let handler: EditorKeyboardHandler
    @Binding var selection: ClosedRange<Double>?
    let playhead: () -> Double
    let duration: () -> Double
    let onsets: () -> [Double]
    let seek: (Double) -> Void
    let ensureLoaded: () -> Void
    let onUndo: (() -> Void)?
    let onRedo: (() -> Void)?
    /// Bumps registration when editor context changes (sample, classify mode, etc.).
    var registrationKey: String = ""

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { publish() }
            .onChange(of: registrationKey) { publish() }
            .onDisappear { router.unregister(handler: handler) }
    }

    private func publish() {
        router.setRegistration(EditorKeyboardRouter.Registration(
            handler: handler,
            selection: $selection,
            playhead: playhead,
            duration: duration,
            onsets: onsets,
            seek: seek,
            ensureLoaded: ensureLoaded,
            onUndo: onUndo,
            onRedo: onRedo
        ))
    }
}
