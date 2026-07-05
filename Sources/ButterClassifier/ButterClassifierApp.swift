import SwiftUI
import SwiftData
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) so a window appears.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ButterClassifierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let container: ModelContainer = {
        do {
            let container = try ModelContainer(for: WatchedFolder.self, SampleFile.self)
            seedFoldersFromCommandLine(container: container)
            return container
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup("Butter Classifier") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 620)
        }
        .modelContainer(container)
    }
}

/// Supports `ButterClassifier --add-folder /path/to/samples` for scripted setup.
@MainActor
private func seedFoldersFromCommandLine(container: ModelContainer) {
    let args = CommandLine.arguments
    let context = container.mainContext
    for (i, arg) in args.enumerated() where arg == "--add-folder" && i + 1 < args.count {
        let path = (args[i + 1] as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
        let existing = (try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []
        if !existing.contains(where: { $0.path == path }) {
            context.insert(WatchedFolder(path: path))
        }
    }
    try? context.save()
}
