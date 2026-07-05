import SwiftUI
import SwiftData
import AppKit

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WatchedFolder.dateAdded) private var folders: [WatchedFolder]
    @Query private var samples: [SampleFile]

    @StateObject private var runner = AnalyzerRunner()
    @StateObject private var player = AudioPlayer()

    @State private var selectedFolderPath: String?   // nil = all folders
    @State private var selectedSampleID: PersistentIdentifier?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\SampleFile.name)]
    @State private var showLog = false
    @State private var bpmOverrideText = ""

    private var visibleSamples: [SampleFile] {
        var result = samples
        if let folder = selectedFolderPath {
            result = result.filter { $0.watchedFolderPath == folder }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return result.sorted(using: sortOrder)
    }

    private var selectedSample: SampleFile? {
        guard let id = selectedSampleID else { return nil }
        return samples.first { $0.persistentModelID == id }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                table
                if runner.isRunning || !runner.queue.isEmpty {
                    analysisStatusBar
                }
                if let sample = selectedSample {
                    Divider()
                    DetailPane(sample: sample, player: player) {
                        rescan()
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search samples")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showLog) { logSheet }
        .alert("Analyzer runtime missing", isPresented: $runner.runtimeMissing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The bundled Python runtime was not found. Rebuild the app, or run python/build_runtime.sh and set BUTTER_ANALYZER_DIR for development.")
        }
        .onAppear {
            runner.onJobFinished = { rescan() }
            rescan()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedFolderPath) {
            Section("Library") {
                Label("All Samples", systemImage: "music.note.list")
                    .tag(String?.none)
            }
            Section("Folders") {
                ForEach(folders, id: \.path) { folder in
                    Label(folder.name, systemImage: "folder")
                        .tag(String?.some(folder.path))
                        .contextMenu {
                            Button("Analyze Folder") {
                                runner.enqueue(path: folder.path)
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                            }
                            Divider()
                            Button("Remove from Library", role: .destructive) {
                                removeFolder(folder)
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                addFolder()
            } label: {
                Label("Add Folder…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .padding(10)
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(visibleSamples, selection: $selectedSampleID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.isAnalyzed ? "waveform.circle.fill" : "circle.dotted")
                        .foregroundStyle(s.isAnalyzed ? Color.accentColor : Color.secondary)
                        .help(s.isAnalyzed ? "Analyzed" : "Not analyzed")
                    Text(s.name)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Duration", value: \.durationSort) { s in
                Text(s.duration.map { String(format: "%.2fs", $0) } ?? "—")
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("BPM", value: \.bpmSort) { s in
                Text(s.bpm.map { String(format: "%.1f", $0) } ?? "—")
                    .monospacedDigit()
            }
            .width(60)

            TableColumn("LUFS", value: \.loudnessSort) { s in
                Text(s.loudnessLUFS.map { String(format: "%.1f", $0) } ?? "—")
                    .monospacedDigit()
            }
            .width(60)

            TableColumn("Kick", value: \.kickinessSort) { s in
                Text(s.kickiness.map { String(format: "%.0f", $0) } ?? "—")
                    .monospacedDigit()
            }
            .width(50)

            TableColumn("Swing 8th", value: \.swing8Sort) { s in
                Text(s.swing8th.map { String(format: "%.3f", $0) } ?? "—")
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Swing 16th", value: \.swing16Sort) { s in
                Text(s.swing16th.map { String(format: "%.3f", $0) } ?? "—")
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Folder") { s in
                Text((s.folderPath as NSString).lastPathComponent)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 160)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let id = ids.first, let s = samples.first(where: { $0.persistentModelID == id }) {
                Button(s.isAnalyzed ? "Re-analyze" : "Analyze") {
                    runner.enqueue(path: s.path, bpmOverride: bpmOverride, force: s.isAnalyzed)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([s.url])
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let s = samples.first(where: { $0.persistentModelID == id }) {
                selectedSampleID = id
                player.togglePlay(url: s.url)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Rescan watched folders")

            Menu {
                Button("Analyze Selected File") {
                    if let s = selectedSample {
                        runner.enqueue(path: s.path, bpmOverride: bpmOverride, force: s.isAnalyzed)
                    }
                }
                .disabled(selectedSample == nil)

                Button("Analyze Current Folder") {
                    if let folder = selectedFolderPath {
                        enqueueUnanalyzedFolders(inWatchedFolder: folder)
                    }
                }
                .disabled(selectedFolderPath == nil)

                Button("Analyze All Unanalyzed") {
                    enqueueUnanalyzedFolders(inWatchedFolder: nil)
                }
                .disabled(folders.isEmpty)

                Divider()

                TextField("BPM override (optional)", text: $bpmOverrideText)
            } label: {
                Label("Analyze", systemImage: "waveform.badge.magnifyingglass")
            }
            .help("Run the analyzer (skips files that already have a YAML)")

            Button {
                showLog.toggle()
            } label: {
                Label("Log", systemImage: "terminal")
            }
            .help("Show analyzer output")

            if runner.isRunning {
                Button {
                    runner.cancelAll()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .help("Cancel analysis")
            }
        }
    }

    private var bpmOverride: Double? {
        Double(bpmOverrideText.trimmingCharacters(in: .whitespaces))
    }

    /// The analyzer script's directory mode is non-recursive (os.listdir), while
    /// our library scan is recursive. So we enqueue every distinct directory
    /// that contains at least one unanalyzed sample.
    private func enqueueUnanalyzedFolders(inWatchedFolder watched: String?) {
        var dirs = Set<String>()
        for s in samples where !s.isAnalyzed {
            if let watched, s.watchedFolderPath != watched { continue }
            dirs.insert(s.folderPath)
        }
        for dir in dirs.sorted() {
            runner.enqueue(path: dir, bpmOverride: bpmOverride)
        }
    }

    // MARK: - Analysis status / log

    private var analysisStatusBar: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Analyzing: \(runner.currentFileName)")
                .font(.caption)
                .lineLimit(1)
            if runner.completedInJob > 1 {
                Text("(\(runner.completedInJob) files so far)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !runner.queue.isEmpty {
                Text("• \(runner.queue.count) job(s) queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Log") { showLog = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Analyzer Output").font(.headline)
                Spacer()
                Button("Close") { showLog = false }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? "No output yet." : runner.log)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logEnd")
                }
                .onChange(of: runner.log) {
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
            .frame(minWidth: 640, minHeight: 400)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding(16)
    }

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path
            if !folders.contains(where: { $0.path == path }) {
                context.insert(WatchedFolder(path: path))
            }
        }
        try? context.save()
        rescan()
    }

    private func removeFolder(_ folder: WatchedFolder) {
        if selectedFolderPath == folder.path {
            selectedFolderPath = nil
        }
        context.delete(folder)
        try? context.save()
        rescan()
    }

    private func rescan() {
        LibraryScanner.scanAll(context: context)
    }
}
