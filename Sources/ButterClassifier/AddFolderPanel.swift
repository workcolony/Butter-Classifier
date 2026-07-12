import AppKit

/// Folder picker with separate “index only” vs “index + analyze” actions.
enum AddFolderPanel {
    enum Action {
        case addOnly
        case addAndAnalyze
    }

    struct Outcome {
        let urls: [URL]
        let action: Action
    }

    @MainActor
    static func run() -> Outcome? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more sample folders, then confirm."

        let controller = Controller()
        panel.accessoryView = controller.makeAccessoryView(panel: panel)
        panel.isAccessoryViewDisclosed = false
        controller.applyAction(.addOnly, to: panel)

        guard panel.runModal() == .OK else { return nil }
        guard !panel.urls.isEmpty else { return nil }
        return Outcome(urls: panel.urls, action: controller.action)
    }

    @MainActor
    private final class Controller: NSObject {
        var action: Action = .addOnly
        private weak var panel: NSOpenPanel?
        private weak var addOnlyButton: NSButton?
        private weak var analyzeButton: NSButton?

        func makeAccessoryView(panel: NSOpenPanel) -> NSView {
            self.panel = panel

            let hint = NSTextField(labelWithString: "Choose an action, select folders, then click the confirm button.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 2
            hint.translatesAutoresizingMaskIntoConstraints = false

            let addOnly = NSButton(
                title: "Add to Library",
                target: self,
                action: #selector(selectAddOnly)
            )
            addOnly.bezelStyle = .rounded
            addOnly.setButtonType(.pushOnPushOff)
            addOnly.translatesAutoresizingMaskIntoConstraints = false
            addOnlyButton = addOnly

            let analyze = NSButton(
                title: "Add & Analyze",
                target: self,
                action: #selector(selectAddAndAnalyze)
            )
            analyze.bezelStyle = .rounded
            analyze.setButtonType(.pushOnPushOff)
            analyze.toolTip = "Add folders and queue analysis for files without a YAML sidecar"
            analyze.translatesAutoresizingMaskIntoConstraints = false
            analyzeButton = analyze

            let stack = NSStackView(views: [hint, addOnly, analyze])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            stack.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 44))
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                hint.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            ])
            return container
        }

        @objc private func selectAddOnly() {
            applyAction(.addOnly, to: panel)
        }

        @objc private func selectAddAndAnalyze() {
            applyAction(.addAndAnalyze, to: panel)
        }

        fileprivate func applyAction(_ action: Action, to panel: NSOpenPanel?) {
            self.action = action
            addOnlyButton?.state = action == .addOnly ? .on : .off
            analyzeButton?.state = action == .addAndAnalyze ? .on : .off
            panel?.prompt = action == .addOnly ? "Add to Library" : "Add & Analyze"
        }
    }
}
