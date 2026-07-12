import SwiftUI
import SwiftData
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ButterClassifierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var analyzerRunner = AnalyzerRunner()

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
                .environmentObject(analyzerRunner)
                .frame(minWidth: 1000, minHeight: 620)
                .task {
                    analyzerRunner.maxWorkers = AnalysisSettings.resolvedParallelWorkers()
                    analyzerRunner.warmUp()
                }
        }
        .modelContainer(container)
        .commands {
            InspectorCommands()
        }
    }
}

/// Supports `ButterClassifier --add-folder /path/to/samples` for scripted setup.
@MainActor
private func seedFoldersFromCommandLine(container: ModelContainer) {
    let args = CommandLine.arguments
    let context = container.mainContext
    for (i, arg) in args.enumerated() where arg == "--add-folder" && i + 1 < args.count {
        let path = FolderURLResolver.resolvePath((args[i + 1] as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
        let existing = (try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []
        if !existing.contains(where: { $0.path == path }) {
            context.insert(WatchedFolder(path: path))
        }
    }
    try? context.save()
}
