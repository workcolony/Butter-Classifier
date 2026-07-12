import SwiftUI
import SwiftData
import AppKit

private let allSamplesSidebarID = "__butter_all_samples__"

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WatchedFolder.dateAdded) private var folders: [WatchedFolder]
    @Query private var samples: [SampleFile]

    @EnvironmentObject private var runner: AnalyzerRunner
    @State private var player = AudioPlayer()
    @StateObject private var tagZoneStore = TagZoneStore()
    @StateObject private var tagVocabulary = TagVocabularyStore()

    @State private var selectedSidebarID: String = allSamplesSidebarID
    @State private var selectedSampleIDs: Set<PersistentIdentifier> = []
    @State private var focusedSampleID: PersistentIdentifier?
    @State private var selectionAnchorID: PersistentIdentifier?
    @State private var tableScrollTargetID: PersistentIdentifier?
    @State private var tableScrollToken = 0
    @State private var suppressSelectionAnchorReset = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var sortOrder = [KeyPathComparator(\SampleFileRow.name)]
    @State private var listRows: [SampleFileRow] = []
    @State private var sampleLookup: [PersistentIdentifier: SampleFile] = [:]
    @State private var folderScopedCount = 0
    @State private var listRebuildTask: Task<Void, Never>?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showLog = false
    @State private var showLibrary = false
    @State private var showTagZones = false
    @State private var showProc = false
    @State private var waveformSelection: ClosedRange<Double>?
    @State private var tagsCatalogRevision = 0
    @State private var suggestionRevision = 0
    @State private var catalogKnownTags: [String] = []
    @State private var catalogTagCounts: [String: Int] = [:]
    @State private var catalogRefreshTask: Task<Void, Never>?
    @State private var libraryScanProgress: (completed: Int, total: Int)?
    @State private var bpmOverrideText = ""
    @State private var editorFocused = false
    @State private var keyboardRouter = EditorKeyboardRouter()
    @AppStorage("parallelWorkers") private var parallelWorkers = 0
    @AppStorage("playbackVolume") private var playbackVolume = 1.0
    @AppStorage("resumeFromStopPosition") private var resumeFromStopPosition = false
    @AppStorage("showLibrarySidebar") private var showLibrarySidebar = true
    @AppStorage("sidebarColumnWidth") private var storedSidebarColumnWidth = 220.0
    @AppStorage("procColumnWidth") private var storedProcColumnWidth = 520.0

    private var safeMaxParallel: Int { AnalysisSettings.safeMaxParallelWorkers }

    private var selectedSamples: [SampleFile] {
        selectedSampleIDs.compactMap { sampleLookup[$0] }
    }

    /// Row shown in the detail pane — keyboard focus, else first selected.
    private var detailSample: SampleFile? {
        if let id = focusedSampleID, let s = sampleLookup[id] {
            return s
        }
        if let id = selectedSampleIDs.first {
            return sampleLookup[id]
        }
        return nil
    }

    /// Sample to preview/play (follows arrow-key focus).
    private var playbackSample: SampleFile? {
        detailSample ?? selectedSamples.first
    }

    private var knownTags: [String] { catalogKnownTags }
    private var tagCounts: [String: Int] { catalogTagCounts }
    private var selectedFolderPath: String? {
        selectedSidebarID == allSamplesSidebarID ? nil : selectedSidebarID
    }

    private func refreshTagCatalog() {
        catalogKnownTags = TagCatalog.knownTags(
            preset: tagZoneStore.selected,
            userVocabulary: tagVocabulary.tags,
            libraryTags: TagCatalog.libraryTagSet(in: samples)
        )
        catalogTagCounts = TagCatalog.counts(in: samples)
    }

    private func refreshTagCatalogLight() {
        catalogKnownTags = TagCatalog.knownTags(
            preset: tagZoneStore.selected,
            userVocabulary: tagVocabulary.tags,
            libraryTags: TagCatalog.libraryTagSet(in: samples)
        )
    }

    private func scheduleTagCatalogRefresh(counts: Bool = true) {
        catalogRefreshTask?.cancel()
        catalogRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            if counts {
                refreshTagCatalog()
            } else {
                refreshTagCatalogLight()
            }
        }
    }

    private func syncFocusedSampleFromSelection() {
        if let focused = focusedSampleID, selectedSampleIDs.contains(focused) {
            return
        }
        for row in listRows where selectedSampleIDs.contains(row.id) {
            focusedSampleID = row.id
            return
        }
        focusedSampleID = nil
    }

    private func resetSelectionAnchor() {
        selectionAnchorID = nil
    }

    private func rebuildListRows() {
        listRows = SampleFileListCache.rows(
            from: samples,
            folderPath: selectedFolderPath,
            searchText: debouncedSearchText,
            sortOrder: sortOrder
        )
        sampleLookup = SampleFileListCache.lookup(from: samples)
        folderScopedCount = selectedFolderPath.map { folder in
            samples.filter { $0.watchedFolderPath == folder }.count
        } ?? samples.count
    }

    private func scheduleListRebuild() {
        listRebuildTask?.cancel()
        listRebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            rebuildListRows()
        }
    }

    private func patchListRow(for sample: SampleFile) {
        sampleLookup[sample.persistentModelID] = sample
        let row = SampleFileRow(sample)
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let folder = selectedFolderPath, sample.watchedFolderPath != folder { return }
        if !query.isEmpty, !sample.name.localizedCaseInsensitiveContains(query) { return }
        if let index = listRows.firstIndex(where: { $0.id == row.id }) {
            listRows[index] = row
        } else {
            scheduleListRebuild()
        }
    }

    private func notifyTagsChanged() {
        tagsCatalogRevision += 1
        if selectedSamples.count > 1 {
            for sample in selectedSamples { patchListRow(for: sample) }
        } else if let sample = detailSample {
            patchListRow(for: sample)
        }
    }

    var body: some View {
        contentWithSheets
            .onAppear(perform: handleAppear)
            .onChange(of: parallelWorkers, handleParallelWorkersChange)
            .onChange(of: resumeFromStopPosition) { _, value in
                player.resumeFromStopPosition = value
            }
            .onChange(of: tagsCatalogRevision) { _, _ in scheduleTagCatalogRefresh() }
            .onChange(of: tagZoneStore.selectedIndex) { refreshTagCatalog() }
            .onChange(of: tagVocabulary.tags) { _, _ in refreshTagCatalogLight() }
            .onChange(of: selectedSampleIDs) { _, _ in
                syncFocusedSampleFromSelection()
                if suppressSelectionAnchorReset {
                    suppressSelectionAnchorReset = false
                } else {
                    resetSelectionAnchor()
                }
            }
            .onChange(of: focusedSampleID) { updateEditorKeyboardRouting() }
            .onChange(of: samples.count) { _, _ in scheduleListRebuild() }
            .onChange(of: selectedSidebarID) { _, _ in scheduleListRebuild() }
            .onChange(of: sortOrder) { _, _ in scheduleListRebuild() }
            .onChange(of: searchText) { _, newValue in
                searchDebounceTask?.cancel()
                searchDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    debouncedSearchText = newValue
                    scheduleListRebuild()
                }
            }
            .onChange(of: showLibrary) { updateEditorKeyboardRouting() }
            .onChange(of: showLog) { updateEditorKeyboardRouting() }
            .onChange(of: showTagZones) { updateEditorKeyboardRouting() }
            .onChange(of: showProc) { updateEditorKeyboardRouting() }
    }

    private var contentWithSheets: some View {
        navigationSplitView
            .sheet(isPresented: $showLog) { logSheet }
            .sheet(isPresented: $showLibrary) {
                LibraryFinderView(
                    player: player,
                    tagZoneStore: tagZoneStore,
                    tagVocabulary: tagVocabulary,
                    restrictedFolder: selectedFolderPath,
                    tagsCatalogRevision: tagsCatalogRevision,
                    knownTags: knownTags,
                    onRescan: { rescan() },
                    onAdopt: { adoptSample($0) },
                    onTagsChanged: {
                        tagsCatalogRevision += 1
                        scheduleListRebuild()
                    },
                    onVocabularyChanged: { refreshTagCatalogLight() }
                )
            }
            .sheet(isPresented: $showTagZones) {
                TagZonesEditorView(store: tagZoneStore)
            }
            .alert("Analyzer runtime missing", isPresented: $runner.runtimeMissing) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The bundled Python runtime was not found. Rebuild the app, or run python/build_runtime.sh and set BUTTER_ANALYZER_DIR for development.")
            }
    }

    private let minMainDetailWidth: CGFloat = 280
    private let paneDividerWidth: CGFloat = 6

    private var navigationSplitView: some View {
        VStack(spacing: 0) {
            mainCommandBar
            Divider()
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let maxProcWidth = maxProcColumnWidth(for: totalWidth)
                let procWidth = effectiveProcColumnWidth(for: totalWidth)

                HStack(spacing: 0) {
                    if showLibrarySidebar {
                        sidebar
                            .frame(width: sidebarColumnWidth)
                            .frame(maxHeight: .infinity)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(2)

                        sidebarColumnDivider
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(2)
                    }

                    HStack(spacing: 0) {
                        mainDetailColumn
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(0)

                        if showProc {
                            procColumnDivider(maxProcWidth: maxProcWidth)
                            procDetailColumn
                                .frame(width: procWidth)
                                .frame(maxHeight: .infinity)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                        }
                    }
                    .frame(minWidth: minMainDetailWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(0)
                    .focusable()
                    .focusEffectDisabled()
                    .sampleListKeyboard(
                        enabled: !showLibrary && !showLog && !showTagZones,
                        horizontalEnabled: false,
                        onPrevious: { },
                        onNext: { },
                        onPlay: {
                            if let s = playbackSample {
                                player.togglePlay(url: s.url)
                            }
                        }
                    )
                }
                .frame(width: totalWidth, height: geometry.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search samples")
        .background { EditorKeyboardMonitor(router: keyboardRouter) }
        .background {
            SampleListKeyboardRegistrationView(
                router: keyboardRouter,
                isEnabled: { !showLibrary && !showLog && !showTagZones },
                onPrevious: { moveTableSelection(by: -1, extending: $0) },
                onNext: { moveTableSelection(by: 1, extending: $0) },
                registrationKey: listKeyboardRegistrationKey
            )
        }
    }

    private var listKeyboardRegistrationKey: String {
        "\(showLibrary)-\(showLog)-\(showTagZones)-\(listRows.count)"
    }

    private var sidebarColumnWidth: CGFloat {
        CGFloat(min(300, max(180, storedSidebarColumnWidth)))
    }

    private var sidebarColumnDivider: some View {
        ZStack {
            HorizontalPaneResizeHandle(
                onResizeDelta: { delta in
                    let next = storedSidebarColumnWidth - Double(delta)
                    storedSidebarColumnWidth = min(300, max(180, next))
                },
                onResizeEnded: { }
            )
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .frame(width: paneDividerWidth)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func reservedLibrarySidebarWidth() -> CGFloat {
        guard showLibrarySidebar else { return 0 }
        return sidebarColumnWidth + paneDividerWidth
    }

    private func maxProcColumnWidth(for totalWidth: CGFloat) -> CGFloat {
        let reserved = reservedLibrarySidebarWidth() + paneDividerWidth + minMainDetailWidth
        return max(420, totalWidth - reserved)
    }

    private func effectiveProcColumnWidth(for totalWidth: CGFloat) -> CGFloat {
        min(procColumnWidth, maxProcColumnWidth(for: totalWidth))
    }

    private func procColumnDivider(maxProcWidth: CGFloat) -> some View {
        ZStack {
            HorizontalPaneResizeHandle(
                onResizeDelta: { delta in
                    let next = storedProcColumnWidth + Double(delta)
                    storedProcColumnWidth = min(Double(maxProcWidth), max(420, next))
                },
                onResizeEnded: { }
            )
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .frame(width: paneDividerWidth)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var procColumnWidth: CGFloat {
        CGFloat(min(800, max(420, storedProcColumnWidth)))
    }

    private var mainDetailColumn: some View {
        VStack(spacing: 0) {
            if let sample = detailSample {
                SampleDetailStack(
                    sample: sample,
                    tagTargets: selectedSamples.count > 1 ? selectedSamples : [sample],
                    knownTags: knownTags,
                    tagCounts: tagCounts,
                    tagPreset: tagZoneStore.selected,
                    tagVocabulary: tagVocabulary,
                    suggestionRevision: suggestionRevision,
                    player: player,
                    keyboardRouter: keyboardRouter,
                    editorFocused: $editorFocused,
                    waveformSelection: $waveformSelection,
                    onFilesChanged: { rescan() },
                    onEditsChanged: { refreshEditsForSample(path: $0) },
                    onTagsChanged: { notifyTagsChanged() },
                    onVocabularyChanged: { refreshTagCatalogLight() }
                )
            }
            tableSection
                .frame(maxHeight: .infinity)
            bottomStatusBar
        }
    }

    private var tableSection: some View {
        SampleFileTableView(
            rows: listRows,
            sampleLookup: sampleLookup,
            selection: $selectedSampleIDs,
            sortOrder: $sortOrder,
            scrollToRowID: tableScrollTargetID,
            scrollToken: tableScrollToken,
            rowCount: listRows.count,
            onFocus: { focusedSampleID = $0 },
            onPlay: { player.togglePlay(url: $0.url) },
            onAnalyze: { enqueueSamples($0, force: $1) }
        )
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 10) {
            Text(sampleListStatusText)

            if selectedSamples.count > 1 {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(selectedSamples.count) selected")
            } else if let folder = selectedFolderPath {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text((folder as NSString).lastPathComponent)
                    .lineLimit(1)
            }

            if let scan = libraryScanProgress {
                Text("·")
                    .foregroundStyle(.tertiary)
                if scan.total > 0 {
                    ProgressView(value: Double(scan.completed), total: Double(scan.total))
                        .frame(width: 120)
                    Text("Loading files \(scan.completed)/\(scan.total)")
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                    Text("Loading files into library…")
                }
            } else if runner.showsAnalyzerStatus {
                Text("·")
                    .foregroundStyle(.tertiary)
                analyzerProgressContent
            }

            Spacer()

            if runner.showsAnalyzerStatus {
                Button("Log") { showLog = true }
                    .controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var analyzerProgressContent: some View {
        if runner.totalInBatch > 0 {
            ProgressView(value: Double(runner.completedInBatch), total: Double(runner.totalInBatch))
                .frame(width: 120)
            Text("Analyzing \(runner.completedInBatch)/\(runner.totalInBatch)")
                .monospacedDigit()
        } else if runner.preparingRuntime {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16)
            Text("Preparing analyzer runtime…")
        } else if runner.startingWorkers > 0 && runner.readyWorkers == 0 {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16)
            Text("Loading analyzer libraries…")
        } else if runner.startingWorkers > 0 {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16)
            Text("Starting workers…")
        } else if runner.readyWorkers > 0 && !runner.isRunning {
            Text("\(runner.readyWorkers) worker\(runner.readyWorkers == 1 ? "" : "s") ready")
        }

        if !runner.activeFileNames.isEmpty {
            Text(runner.activeFileNames.joined(separator: ", "))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var sampleListStatusText: String {
        let folderTotal = folderScopedCount
        let shown = listRows.count
        if !debouncedSearchText.isEmpty, shown != folderTotal {
            return "\(shown.formatted()) of \(folderTotal.formatted()) items"
        }
        return "\(shown.formatted()) \(shown == 1 ? "item" : "items")"
    }

    private func rescanAsync(analyzeFolders: [String] = []) async {
        libraryScanProgress = (0, 0)
        await LibraryScanner.scanAll(
            context: context,
            tagPreset: tagZoneStore.selected,
            userVocabulary: tagVocabulary.tags,
            onProgress: { completed, total in
                libraryScanProgress = (completed, total)
            }
        )
        libraryScanProgress = nil
        rebuildListRows()
        suggestionRevision += 1

        guard !analyzeFolders.isEmpty else { return }
        let folderSet = Set(analyzeFolders)
        let toAnalyze = samples
            .filter { folderSet.contains($0.watchedFolderPath) && !$0.isAnalyzed }
        enqueueSamples(toAnalyze, force: false)
    }

    private var procDetailColumn: some View {
        Group {
            if let sample = playbackSample {
                procColumn(for: sample)
            } else {
                ContentUnavailableView("No Sample", systemImage: "waveform")
            }
        }
    }

    private func procColumn(for sample: SampleFile) -> some View {
        ProcShellView(
            sample: sample,
            player: player,
            cropRange: waveformSelection,
            onCommitted: { url in
                rescan()
                focusSample(atPath: url.path)
            }
        )
        .id(sample.persistentModelID)
    }

    private func handleAppear() {
        applyParallelWorkerSetting()
        runner.warmUp()
        updateEditorKeyboardRouting()
        player.volume = Float(playbackVolume)
        player.resumeFromStopPosition = resumeFromStopPosition
        migratePlaybackResumePreference()
        runner.onFileFinished = { path in
            refreshAnalyzedFile(path: path)
        }
        refreshTagCatalog()
        rebuildListRows()
        Task {
            migrateHeavySampleFieldsIfNeeded()
            rebuildListRows()
            await rescanAsync()
        }
    }

    private func migrateHeavySampleFieldsIfNeeded() {
        var dirty = false
        for sample in samples {
            if !sample.onsetTimes.isEmpty {
                sample.onsetTimes = []
                dirty = true
            }
            if !sample.suggestedTagNames.isEmpty {
                sample.setTagSuggestions([])
                dirty = true
            }
            if !sample.editOnsetTimes.isEmpty {
                sample.editOnsetTimes = []
                dirty = true
            }
        }
        if dirty { try? context.save() }
    }

    private func handleParallelWorkersChange() {
        applyParallelWorkerSetting()
        runner.warmUp()
    }

    private func refreshEditsForSample(path: String) {
        guard let sample = samples.first(where: { $0.path == path }) else { return }
        guard LibraryScanner.refreshEdits(for: sample) else { return }
        try? context.save()
        patchListRow(for: sample)
    }

    private func refreshEditsForDetailSample() {
        guard let sample = detailSample else { return }
        refreshEditsForSample(path: sample.path)
    }

    private func updateEditorKeyboardRouting() {
        keyboardRouter.setEnabled(
            detailSample != nil && !showLibrary && !showLog && !showTagZones
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSidebarID) {
            Section("Library") {
                sidebarRow(title: "All Samples", systemImage: "music.note.list", tag: allSamplesSidebarID)
            }
            Section("Folders") {
                ForEach(folders, id: \.path) { folder in
                    sidebarRow(title: folder.name, systemImage: "folder", tag: folder.path)
                        .contextMenu {
                            Button("Analyze Folder") {
                                enqueueUnanalyzed(inWatchedFolder: folder.path)
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
        .listStyle(.sidebar)
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

    private func sidebarRow(title: String, systemImage: String, tag: String) -> some View {
        Label(title, systemImage: systemImage)
            .tag(tag)
            .contentShape(Rectangle())
    }

    // MARK: - Command bar

    private var mainCommandBar: some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            navigationCommands.toolbarCluster()
            analysisCommands.toolbarCluster()
            PlaybackOutputControls(player: player, playbackVolume: $playbackVolume)
                .toolbarCluster()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var navigationCommands: some View {
        HStack(spacing: 8) {
            Button {
                showLibrarySidebar.toggle()
            } label: {
                Label("Folders", systemImage: "sidebar.left")
            }
            .help(showLibrarySidebar ? "Hide library folder list" : "Show library folder list")
            .symbolVariant(showLibrarySidebar ? .fill : .none)

            Button {
                showLibrary = true
            } label: {
                Label("Library", systemImage: "square.grid.3x1.folder.badge.plus")
            }
            .help("Open the sample finder (LUP-style library)")
            .disabled(samples.isEmpty)

            Button {
                showTagZones = true
            } label: {
                Label("Tag Zones", systemImage: "rectangle.split.3x1")
            }
            .help("Edit global tag zone presets")

            Button {
                showProc.toggle()
            } label: {
                Label("PROC", systemImage: "wand.and.stars")
            }
            .help("Audio processing shell (preview → commit)")
            .disabled(playbackSample == nil)
            .symbolVariant(showProc ? .fill : .none)
        }
    }

    private var analysisCommands: some View {
        HStack(spacing: 8) {
            Button {
                rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Rescan watched folders")

            Menu {
                let count = selectedSamples.count
                Button(count <= 1 ? "Analyze Selected" : "Analyze Selected (\(count))") {
                    enqueueSamples(selectedSamples, force: false)
                }
                .disabled(count == 0)

                Button(count <= 1 ? "Re-analyze Selected" : "Re-analyze Selected (\(count))") {
                    enqueueSamples(selectedSamples, force: true)
                }
                .disabled(count == 0)

                Button("Analyze Current Folder") {
                    if let folder = selectedFolderPath {
                        enqueueUnanalyzed(inWatchedFolder: folder)
                    }
                }
                .disabled(selectedFolderPath == nil)

                Button("Analyze All Unanalyzed") {
                    enqueueUnanalyzed(inWatchedFolder: nil)
                }
                .disabled(folders.isEmpty)

                Divider()

                Picker("Files in Parallel (max \(safeMaxParallel))", selection: $parallelWorkers) {
                    ForEach(AnalysisSettings.parallelWorkerOptions(), id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)

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

    /// Sensible worker-count choices up to the safe maximum.
    private func applyParallelWorkerSetting() {
        if parallelWorkers <= 0 {
            parallelWorkers = AnalysisSettings.defaultParallelWorkers
        } else {
            parallelWorkers = AnalysisSettings.clamp(parallelWorkers)
        }
        runner.maxWorkers = parallelWorkers
    }

    /// One-time migration from the old reset-on-stop preference.
    private func migratePlaybackResumePreference() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "resumeFromStopPosition") == nil,
              let legacy = defaults.object(forKey: "resetPlayheadOnStop") as? Bool else { return }
        resumeFromStopPosition = !legacy
        player.resumeFromStopPosition = resumeFromStopPosition
    }

    private func enqueueSamples(_ samples: [SampleFile], force: Bool) {
        let files = samples
            .sorted { $0.path < $1.path }
            .map {
                AnalyzerRunner.FileTask(
                    path: $0.path,
                    bpmOverride: bpmOverride ?? $0.editBpmOverride,
                    quick: false,
                    force: force
                )
            }
        runner.enqueue(files: files)
    }

    private func enqueueUnanalyzed(inWatchedFolder watched: String?) {
        let files = samples
            .filter { !$0.isAnalyzed && (watched == nil || $0.watchedFolderPath == watched) }
            .sorted { $0.path < $1.path }
            .map {
                AnalyzerRunner.FileTask(
                    path: $0.path,
                    bpmOverride: bpmOverride ?? $0.editBpmOverride,
                    quick: false,
                    force: false
                )
            }
        runner.enqueue(files: files)
    }

    /// Refresh a single sample's cached metrics after its YAML was written.
    private func refreshAnalyzedFile(path: String) {
        Task { @MainActor in
            guard let sample = samples.first(where: { $0.path == path }) else {
                await rescanAsync()
                return
            }
            _ = await LibraryScanner.refreshAnalysis(for: sample)
            LibraryScanner.refreshTags(for: sample)
            LibraryScanner.refreshEdits(for: sample)
            try? context.save()
            patchListRow(for: sample)
        }
    }

    private func adoptSample(_ sample: SampleFile) {
        selectedSampleIDs = [sample.persistentModelID]
        focusedSampleID = sample.persistentModelID
        selectionAnchorID = sample.persistentModelID
        tableScrollTargetID = sample.persistentModelID
        tableScrollToken &+= 1
        showLibrary = false
    }

    private func focusSample(atPath path: String) {
        var descriptor = FetchDescriptor<SampleFile>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        if let sample = try? context.fetch(descriptor).first {
            adoptSample(sample)
            return
        }
        if let sample = samples.first(where: { $0.path == path }) {
            adoptSample(sample)
        }
    }

    private func moveTableSelection(by delta: Int, extending: Bool) {
        guard !listRows.isEmpty else { return }
        let ids = listRows.map(\.id)
        let currentID = SampleListNavigation.primaryRow(
            in: ids,
            focus: focusedSampleID,
            selection: selectedSampleIDs
        )
        guard let nextID = SampleListNavigation.move(in: ids, current: currentID, by: delta) else { return }

        if extending {
            if selectionAnchorID == nil {
                selectionAnchorID = currentID ?? nextID
            }
            if let anchor = selectionAnchorID {
                suppressSelectionAnchorReset = true
                selectedSampleIDs = SampleListNavigation.rangedSelection(
                    in: ids,
                    anchor: anchor,
                    end: nextID
                )
            } else {
                selectedSampleIDs = [nextID]
            }
        } else {
            selectionAnchorID = nextID
            selectedSampleIDs = [nextID]
        }

        focusedSampleID = nextID
        tableScrollTargetID = nextID
        tableScrollToken &+= 1
    }

    // MARK: - Log sheet

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Analyzer Output").font(.headline)
                Spacer()
                Toggle("Verbose", isOn: $runner.verboseLog)
                    .toggleStyle(.checkbox)
                    .help("Show full per-file analyzer script output")
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
        guard let outcome = AddFolderPanel.run() else { return }
        let folderPaths = outcome.urls.map { FolderURLResolver.resolvePath($0.path) }
        for path in folderPaths {
            if !folders.contains(where: { $0.path == path }) {
                context.insert(WatchedFolder(path: path))
            }
        }
        try? context.save()
        if outcome.action == .addAndAnalyze {
            Task { await rescanAsync(analyzeFolders: folderPaths) }
        } else {
            rescan()
        }
    }

    private func removeFolder(_ folder: WatchedFolder) {
        if selectedFolderPath == folder.path {
            selectedSidebarID = allSamplesSidebarID
        }
        context.delete(folder)
        try? context.save()
        rescan()
    }

    private func rescan() {
        Task { await rescanAsync() }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func hideToolbarSharedBackgroundIfAvailable() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
