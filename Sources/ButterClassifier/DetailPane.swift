import SwiftUI
import SwiftData

/// Bottom pane: waveform player and editing tools for the selected sample.
struct DetailPane: View {
    let sample: SampleFile
    let tagTargets: [SampleFile]
    let player: AudioPlayer
    let keyboardRouter: EditorKeyboardRouter
    @Binding var editorFocused: Bool
    @Binding var selection: ClosedRange<Double>?
    var onFilesChanged: () -> Void
    var onEditsChanged: (String) -> Void

    @AppStorage("waveformMode") private var waveformModeRaw = WaveformMode.original.rawValue
    @AppStorage(WaveformColorTheme.storageKey) private var waveformThemeID = WaveformColorTheme.system.id
    @AppStorage("waveformPaneHeight") private var storedWaveformPaneHeight = 130.0
    @State private var liveWaveformHeight: CGFloat?
    @State private var renderModel: WaveformRenderModel = .empty
    @State private var keyboardHandler = EditorKeyboardHandler()
    @State private var statusMessage = ""
    @State private var classifyMode = false
    @State private var edits = SampleEdits.empty
    @State private var editableOnsets: [Double] = []
    @State private var classifyUndoStack: [ClassificationSnapshot] = []
    @State private var classifyRedoStack: [ClassificationSnapshot] = []
    @State private var isRestoringClassifyHistory = false
    /// Blocks auto-persist while loadEdits (or undo/redo) applies state — SwiftUI onChange can fire after sync returns.
    @State private var suppressAutoPersistEdits = false
    @State private var loopRange: ClosedRange<Double>?
    @State private var bpmOverrideText = ""
    @State private var keyOverrideText = ""
    @State private var lastKnownEditsMtime: Date?
    @State private var persistEditsTask: Task<Void, Never>?
    @State private var activeSamplePath = ""
    @State private var cachedAnalyzedOnsets: [Double] = []
    @State private var waveformZoom: Double = 1.0
    @State private var scrollFraction: Double = 0
    @AppStorage("waveformScrollMode") private var scrollModeRaw = WaveformScrollMode.continuous.rawValue

    private var scrollMode: WaveformScrollMode {
        WaveformScrollMode(rawValue: scrollModeRaw) ?? .continuous
    }

    private var waveformMode: WaveformMode {
        WaveformMode(rawValue: waveformModeRaw) ?? .original
    }

    private var waveformTheme: ResolvedWaveformTheme {
        WaveformColorTheme.theme(id: waveformThemeID).resolved()
    }

    private var waveformMinHeight: CGFloat {
        switch waveformMode {
        case .chromagram, .ribbon: return 150
        default: return 130
        }
    }

    private var waveformMaxHeight: CGFloat { waveformMinHeight * 4 }

    private var displayWaveformHeight: CGFloat {
        let base = liveWaveformHeight ?? CGFloat(storedWaveformPaneHeight)
        return base.clamped(to: waveformMinHeight...waveformMaxHeight)
    }

    private var waveformDuration: Double {
        max(renderModel.duration, renderModel.waveform.duration, 0.0001)
    }

    private var waveformMaxZoom: Double {
        WaveformViewport.maxZoom(duration: waveformDuration)
    }

    var body: some View {
        VStack(spacing: 8) {
            DetailPaneHeader(
                sample: sample,
                tagTargets: tagTargets,
                onsetCount: editableOnsets.count,
                bpmOverride: edits.bpmOverride,
                keyOverride: edits.keyOverride,
                statusMessage: statusMessage
            )
            waveformModeBar
            DetailPaneWaveform(
                sample: sample,
                player: player,
                mode: waveformMode,
                theme: waveformTheme,
                renderModel: renderModel,
                classifyMode: classifyMode,
                editableOnsets: $editableOnsets,
                loopRange: $loopRange,
                zoom: $waveformZoom,
                scrollMode: scrollMode,
                scrollFraction: $scrollFraction,
                selection: $selection,
                onWillChangeOnsets: recordClassifyCheckpoint,
                onWillChangeLoop: recordClassifyCheckpoint,
                onSelectionDragBegan: { keyboardHandler.shiftSession.reset() },
                onPlaybackRegionChanged: syncPlaybackRegion
            )
            .frame(height: displayWaveformHeight)
            .animation(nil, value: displayWaveformHeight)
            waveformResizeHandle
            ClassificationBar(
                classifyMode: $classifyMode,
                bpmOverrideText: $bpmOverrideText,
                keyOverrideText: $keyOverrideText,
                hasLoop: loopRange != nil,
                onsetCount: editableOnsets.count,
                onAddOnset: addOnsetAtPlayhead,
                onDeleteNearestOnset: deleteNearestOnset,
                onResetOnsets: resetOnsets,
                onClearEditsFile: clearEditsFile,
                onSetLoopFromSelection: setLoopFromSelection,
                onClearLoop: clearLoop,
                onApplyScalars: applyScalars
            )
            DetailPaneControls(
                sample: sample,
                player: player,
                selection: $selection,
                sliceOnsets: editableOnsets,
                onFilesChanged: onFilesChanged,
                onStatus: { statusMessage = $0 }
            )
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { editorFocused = true }
        .background {
            EditorKeyboardRegistrationView(
                router: keyboardRouter,
                handler: keyboardHandler,
                selection: $selection,
                playhead: { player.loadedPath == sample.path ? player.currentTime : 0 },
                duration: {
                    if player.loadedPath == sample.path, player.duration > 0 { return player.duration }
                    return sample.duration ?? renderModel.duration
                },
                onsets: { editableOnsets },
                seek: { t in
                    ensureSampleLoaded()
                    player.seek(to: t)
                },
                ensureLoaded: { ensureSampleLoaded() },
                onUndo: classifyMode ? { undoClassifyEdits() } : nil,
                onRedo: classifyMode ? { redoClassifyEdits() } : nil,
                registrationKey: "\(sample.path)|\(classifyMode)"
            )
        }
        .task(id: sample.path) {
            persistEditsTask?.cancel()
            persistEditsTask = nil
            let leavingPath = activeSamplePath
            if !leavingPath.isEmpty && leavingPath != sample.path {
                flushPendingEdits(for: leavingPath)
            }
            activeSamplePath = sample.path
            selection = nil
            keyboardHandler.shiftSession.reset()
            statusMessage = ""
            classifyMode = false
            waveformZoom = 1.0
            scrollFraction = 0
            if storedWaveformPaneHeight < Double(waveformMinHeight) {
                storedWaveformPaneHeight = Double(waveformMinHeight)
            }
            player.playbackRegion = nil
            loadEdits()
        }
        .task(id: sample.path) {
            await watchExternalEdits()
        }
        .task(id: "\(sample.path)|\(waveformModeRaw)") {
            let path = sample.path
            let url = sample.url
            let yamlURL = sample.yamlURL
            let mode = waveformMode
            let analyzed = sample.isAnalyzed

            let quick = await WaveformRenderModel.loadWaveformOnly(url: url, mode: mode)
            guard !Task.isCancelled, sample.path == path else { return }
            renderModel = quick

            guard analyzed else { return }
            let full = await WaveformRenderModel.load(
                url: url,
                yamlURL: yamlURL,
                mode: mode,
                isAnalyzed: analyzed
            )
            guard !Task.isCancelled, sample.path == path else { return }
            renderModel = full
        }
        .onDisappear {
            flushPendingEdits(for: activeSamplePath)
        }
        .onChange(of: editableOnsets) { _, _ in
            guard !suppressAutoPersistEdits else { return }
            schedulePersistEdits()
        }
        .onChange(of: loopRange) { _, newLoop in
            player.loopRegion = newLoop
            guard !suppressAutoPersistEdits else { return }
            schedulePersistEdits()
        }
        .onChange(of: selection) { _, newSelection in
            syncPlaybackRegion(newSelection)
        }
        .onChange(of: waveformZoom) { _, z in
            if z <= 1.01 { scrollFraction = 0 }
        }
        .onChange(of: renderModel.duration) { _, _ in
            if waveformZoom > waveformMaxZoom {
                waveformZoom = waveformMaxZoom
            }
        }
        .onChange(of: classifyMode) { _, isOn in
            if !isOn { commitOnsetEdits() }
        }
    }

    private func syncPlaybackRegion(_ newSelection: ClosedRange<Double>?) {
        if let sel = newSelection, sel.upperBound - sel.lowerBound > 0.001 {
            player.playbackRegion = sel
        } else {
            player.playbackRegion = nil
            keyboardHandler.shiftSession.reset()
        }
    }

    private struct EditsSnapshot {
        let path: String
        let onsets: [Double]
        let loopRange: ClosedRange<Double>?
        let bpmText: String
        let keyText: String
        let trackOnsets: Bool
        let analyzedOnsets: [Double]
    }

    private func watchExternalEdits() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let shouldReload = await MainActor.run { () -> Bool in
                guard activeSamplePath == sample.path else { return false }
                guard !classifyMode, !isRestoringClassifyHistory else { return false }
                let diskMtime = EditSidecar.modificationDate(forAudioPath: sample.path)
                return diskMtime != lastKnownEditsMtime
            }
            guard shouldReload else { continue }
            await MainActor.run {
                loadEdits()
                onEditsChanged(sample.path)
            }
        }
    }

    private func commitOnsetEdits() {
        classifyUndoStack.removeAll()
        classifyRedoStack.removeAll()
    }

    private struct ClassificationSnapshot {
        var onsets: [Double]
        var loopRange: ClosedRange<Double>?
        var bpmText: String
        var keyText: String
    }

    private func currentClassifySnapshot() -> ClassificationSnapshot {
        ClassificationSnapshot(
            onsets: editableOnsets,
            loopRange: loopRange,
            bpmText: bpmOverrideText,
            keyText: keyOverrideText
        )
    }

    private func applyClassifySnapshot(_ snapshot: ClassificationSnapshot) {
        suppressAutoPersistEdits = true
        isRestoringClassifyHistory = true
        editableOnsets = snapshot.onsets
        loopRange = snapshot.loopRange
        player.loopRegion = loopRange
        bpmOverrideText = snapshot.bpmText
        keyOverrideText = snapshot.keyText
        isRestoringClassifyHistory = false
        suppressAutoPersistEdits = false
        persistEdits()
    }

    private func analyzedOnsets() -> [Double] {
        cachedAnalyzedOnsets
    }

    private func loadEdits() {
        guard activeSamplePath == sample.path else { return }
        suppressAutoPersistEdits = true
        let path = sample.path
        let yamlURL = sample.yamlURL
        edits = EditSidecar.load(fromAudioPath: path)
        lastKnownEditsMtime = EditSidecar.modificationDate(forAudioPath: path)
        editableOnsets = sanitizedOnsets(edits.effectiveOnsets(fallback: []))
        classifyUndoStack.removeAll()
        classifyRedoStack.removeAll()
        loopRange = edits.loopRange
        player.loopRegion = loopRange
        bpmOverrideText = edits.bpmOverride.map { String(format: "%.1f", $0) } ?? ""
        keyOverrideText = edits.keyOverride ?? ""
        cachedAnalyzedOnsets = []

        Task {
            let onsets = await Task.detached(priority: .utility) {
                AnalysisResult.load(from: yamlURL, mode: .tagging)?.onsetTimes ?? []
            }.value
            guard !Task.isCancelled, activeSamplePath == path else {
                await MainActor.run { suppressAutoPersistEdits = false }
                return
            }
            cachedAnalyzedOnsets = onsets
            editableOnsets = sanitizedOnsets(edits.effectiveOnsets(fallback: onsets))
            await Task.yield()
            guard !Task.isCancelled, activeSamplePath == path else { return }
            suppressAutoPersistEdits = false
        }
    }

    private func sanitizedOnsets(_ onsets: [Double], audioPath: String? = nil) -> [Double] {
        let path = audioPath ?? sample.path
        let duration = (path == sample.path ? sample.duration : nil)
            ?? (player.loadedPath == path && player.duration > 0 ? player.duration : nil)
            ?? (path == sample.path && renderModel.duration > 0 ? renderModel.duration : nil)
        var values = onsets.filter(\.isFinite).filter { $0 >= 0 }
        guard let duration, duration > 0 else { return values.sorted() }
        values = values.filter { $0 <= duration * 1.05 }
        if values.isEmpty { return values }
        if let maxValue = values.max(), maxValue <= 1.0, duration > 1.5, values.count >= 2 {
            values = values.map { $0 * duration }
        }
        return values.sorted()
    }

    private func captureEditsSnapshot() -> EditsSnapshot {
        let analyzed = sanitizedOnsets(cachedAnalyzedOnsets, audioPath: activeSamplePath)
        let onsets = sanitizedOnsets(editableOnsets, audioPath: activeSamplePath)
        return EditsSnapshot(
            path: activeSamplePath,
            onsets: onsets,
            loopRange: loopRange,
            bpmText: bpmOverrideText,
            keyText: keyOverrideText,
            trackOnsets: edits.onsetTimes != nil || onsetsDiffer(onsets, from: analyzed),
            analyzedOnsets: analyzed
        )
    }

    private func schedulePersistEdits() {
        guard !suppressAutoPersistEdits else { return }
        let snapshot = captureEditsSnapshot()
        guard !snapshot.path.isEmpty, snapshot.path == sample.path, snapshot.path == activeSamplePath else { return }
        persistEditsTask?.cancel()
        persistEditsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            writeEditsSnapshot(snapshot)
        }
    }

    private func flushPendingEdits(for path: String) {
        persistEditsTask?.cancel()
        persistEditsTask = nil
        guard !path.isEmpty, !suppressAutoPersistEdits else { return }
        let snapshot = captureEditsSnapshot()
        guard snapshot.path == path else { return }
        writeEditsSnapshot(snapshot)
    }

    private func writeEditsSnapshot(_ snapshot: EditsSnapshot) {
        guard !snapshot.path.isEmpty else { return }
        let next = editsFromSnapshot(snapshot)
        let existing = EditSidecar.load(fromAudioPath: snapshot.path)
        guard existing != next else { return }
        try? EditSidecar.save(next, audioPath: snapshot.path)
        if snapshot.path == sample.path && snapshot.path == activeSamplePath {
            edits = next
            lastKnownEditsMtime = EditSidecar.modificationDate(forAudioPath: snapshot.path)
        }
        onEditsChanged(snapshot.path)
    }

    private func editsFromSnapshot(_ snapshot: EditsSnapshot) -> SampleEdits {
        var next = SampleEdits()
        let analyzed = snapshot.analyzedOnsets
        if snapshot.trackOnsets || onsetsDiffer(snapshot.onsets, from: analyzed) {
            next.onsetTimes = snapshot.onsets
        }
        if let loop = snapshot.loopRange {
            next.loopStart = loop.lowerBound
            next.loopEnd = loop.upperBound
        }
        if let bpm = Double(snapshot.bpmText.trimmingCharacters(in: .whitespaces)), bpm > 0 {
            next.bpmOverride = bpm
        }
        let key = snapshot.keyText.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { next.keyOverride = key }
        return next
    }

    private func persistEdits() {
        writeEditsSnapshot(captureEditsSnapshot())
    }

    private func recordClassifyCheckpoint() {
        guard classifyMode, !isRestoringClassifyHistory else { return }
        classifyUndoStack.append(currentClassifySnapshot())
        if classifyUndoStack.count > 100 {
            classifyUndoStack.removeFirst(classifyUndoStack.count - 100)
        }
        classifyRedoStack.removeAll()
    }

    private func undoClassifyEdits() {
        guard classifyMode else { return }
        guard let previous = classifyUndoStack.popLast() else { return }
        classifyRedoStack.append(currentClassifySnapshot())
        applyClassifySnapshot(previous)
    }

    private func redoClassifyEdits() {
        guard classifyMode else { return }
        guard let next = classifyRedoStack.popLast() else { return }
        classifyUndoStack.append(currentClassifySnapshot())
        applyClassifySnapshot(next)
    }

    private func addOnsetAtPlayhead() {
        let t = player.loadedPath == sample.path ? player.currentTime : 0
        guard !editableOnsets.contains(where: { abs($0 - t) < 0.01 }) else { return }
        recordClassifyCheckpoint()
        editableOnsets.append(t)
        editableOnsets.sort()
        classifyMode = true
    }

    private func deleteNearestOnset() {
        let t = player.loadedPath == sample.path ? player.currentTime : 0
        guard let idx = editableOnsets.enumerated().min(by: { abs($0.element - t) < abs($1.element - t) })?.offset else { return }
        recordClassifyCheckpoint()
        editableOnsets.remove(at: idx)
    }

    private func resetOnsets() {
        recordClassifyCheckpoint()
        editableOnsets = sanitizedOnsets(analyzedOnsets())
    }

    private func clearEditsFile() {
        recordClassifyCheckpoint()
        try? FileManager.default.removeItem(at: EditSidecar.url(forAudioPath: sample.path))
        edits = .empty
        lastKnownEditsMtime = nil
        suppressAutoPersistEdits = true
        editableOnsets = sanitizedOnsets(analyzedOnsets())
        loopRange = nil
        player.loopRegion = nil
        bpmOverrideText = ""
        keyOverrideText = ""
        suppressAutoPersistEdits = false
        onEditsChanged(sample.path)
        statusMessage = "Cleared classification edits"
    }

    private func setLoopFromSelection() {
        guard let sel = selection, sel.upperBound > sel.lowerBound else { return }
        recordClassifyCheckpoint()
        loopRange = sel
        selection = nil
        classifyMode = true
    }

    private func clearLoop() {
        recordClassifyCheckpoint()
        loopRange = nil
        player.loopRegion = nil
    }

    private func applyScalars() {
        recordClassifyCheckpoint()
        persistEdits()
        statusMessage = "Saved classification edits"
    }

    private func onsetsDiffer(_ edited: [Double], from analyzed: [Double]) -> Bool {
        guard edited.count == analyzed.count else { return true }
        return zip(edited, analyzed).contains { abs($0 - $1) > 0.0005 }
    }

    private func scrollWaveform(by direction: Int) {
        guard waveformZoom > 1.01 else { return }
        let step = scrollMode.step(zoom: waveformZoom) * Double(direction)
        scrollFraction = scrollMode.snapFraction(scrollFraction + step, zoom: waveformZoom)
    }

    private func ensureSampleLoaded() {
        if player.loadedPath != sample.path {
            player.load(url: sample.url)
        }
    }

    private var waveformResizeHandle: some View {
        ZStack {
            VerticalPaneResizeHandle(
                onResizeDelta: { delta in
                    var next = displayWaveformHeight + delta
                    next = next.clamped(to: waveformMinHeight...waveformMaxHeight)
                    liveWaveformHeight = next
                },
                onResizeEnded: {
                    storedWaveformPaneHeight = Double(displayWaveformHeight)
                    liveWaveformHeight = nil
                }
            )
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 48, height: 3)
                .allowsHitTesting(false)
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .help("Drag to resize waveform (up to 4×)")
    }

    private var waveformModeBar: some View {
        FlowLayout(spacing: 10, rowSpacing: 8) {
            waveformModePicker.toolbarCluster()
            if waveformMode.needsAnalysis && !renderModel.hasSpectralData {
                Text("Analyze for \(waveformMode.label.lowercased()) view")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .toolbarCluster()
            }
            waveformZoomControls.toolbarCluster()
            waveformScrollControls.toolbarCluster()
            waveformThemeMenu.toolbarCluster()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var waveformModePicker: some View {
        Picker("Waveform", selection: Binding(
            get: { waveformMode },
            set: { waveformModeRaw = $0.rawValue }
        )) {
            ForEach(WaveformMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Original: 1,200-bin overview. Supersample: 32,768-bin detail — zoom in to compare.")
    }

    private var waveformZoomControls: some View {
        HStack(spacing: 8) {
            Text("Zoom").font(.caption).foregroundStyle(.secondary)
            Slider(value: $waveformZoom, in: 1...waveformMaxZoom, step: 1)
                .frame(width: 120)
                .help("Trackpad: pinch or scroll vertically to zoom; swipe sideways to pan when zoomed. Option/⌘+scroll also zooms. Max zoom scales with clip length.")
            Text("\(Int(waveformZoom))×")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Button {
                waveformZoom = 1
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset waveform zoom")
            .disabled(waveformZoom <= 1.01)
        }
    }

    private var waveformScrollControls: some View {
        HStack(spacing: 8) {
            Picker("Scroll", selection: $scrollModeRaw) {
                ForEach(WaveformScrollMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Button { scrollWaveform(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(waveformZoom <= 1.01)
            .help(scrollMode == .none ? "Nudge left" : "Scroll left")

            Button { scrollWaveform(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(waveformZoom <= 1.01)
            .help(scrollMode == .none ? "Nudge right" : "Scroll right")
        }
    }

    private var waveformThemeMenu: some View {
        Menu {
            ForEach(WaveformColorTheme.all) { theme in
                Button {
                    waveformThemeID = theme.id
                } label: {
                    HStack {
                        WaveformThemeSwatch(theme: theme)
                        Text(theme.name)
                        if waveformThemeID == theme.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("Theme", systemImage: "paintpalette")
        }
        .menuStyle(.borderlessButton)
        .help("Waveform color theme")
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Classification bar

private struct ClassificationBar: View {
    @Binding var classifyMode: Bool
    @Binding var bpmOverrideText: String
    @Binding var keyOverrideText: String
    let hasLoop: Bool
    let onsetCount: Int
    var onAddOnset: () -> Void
    var onDeleteNearestOnset: () -> Void
    var onResetOnsets: () -> Void
    var onClearEditsFile: () -> Void
    var onSetLoopFromSelection: () -> Void
    var onClearLoop: () -> Void
    var onApplyScalars: () -> Void

    var body: some View {
        FlowLayout(spacing: 10, rowSpacing: 8) {
            Toggle("Classify", isOn: $classifyMode)
                .toggleStyle(.button)
                .help("Drag onsets and loop braces. Drag empty waveform to draw a loop. Option-click an onset to delete. Double-click to add an onset. ⌘Z/⇧⌘Z undo/redo onsets, loop, BPM, and key while Classify is on.")
                .toolbarCluster()

            onsetControls.toolbarCluster()
            loopControls.toolbarCluster()
            scalarControls.toolbarCluster()

            Text("\(onsetCount) onsets")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .toolbarCluster()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var onsetControls: some View {
        HStack(spacing: 8) {
            Button("Add Onset") { onAddOnset() }
                .controlSize(.small)
            Button("Delete Near") { onDeleteNearestOnset() }
                .controlSize(.small)
                .disabled(onsetCount == 0)
            Button("Reset Onsets") { onResetOnsets() }
                .controlSize(.small)
            Button("Clear Edits File") { onClearEditsFile() }
                .controlSize(.small)
                .help("Delete _edits.yaml and reload onsets from analysis")
        }
    }

    private var loopControls: some View {
        HStack(spacing: 8) {
            Button("Set Loop") { onSetLoopFromSelection() }
                .controlSize(.small)
                .help("Set loop braces from waveform selection")
            Button("Clear Loop") { onClearLoop() }
                .controlSize(.small)
                .disabled(!hasLoop)
        }
    }

    private var scalarControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                TextField("—", text: $bpmOverrideText)
                    .frame(width: 48)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onApplyScalars() }
            }
            HStack(spacing: 4) {
                Text("Key").font(.caption).foregroundStyle(.secondary)
                TextField("—", text: $keyOverrideText)
                    .frame(width: 52)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onApplyScalars() }
            }
        }
    }
}

// MARK: - Subviews isolated from player ticks

private struct DetailPaneHeader: View {
    let sample: SampleFile
    let tagTargets: [SampleFile]
    let onsetCount: Int
    let bpmOverride: Double?
    let keyOverride: String?
    let statusMessage: String

    var body: some View {
        HStack(spacing: 12) {
            Text(sample.name).font(.headline).lineLimit(1)
            if tagTargets.count > 1 {
                Text("\(tagTargets.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if let d = sample.duration {
                metric("Duration", String(format: "%.2fs", d))
            }
            if let bpm = bpmOverride ?? sample.bpm {
                metric("BPM", String(format: "%.1f", bpm))
            }
            if let key = keyOverride, !key.isEmpty {
                metric("Key", key)
            }
            if let lufs = sample.loudnessLUFS {
                metric("LUFS", String(format: "%.1f", lufs))
            }
            if onsetCount > 0 {
                metric("Onsets", "\(onsetCount)")
            }
            Spacer()
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}

private struct DetailPaneWaveform: View {
    let sample: SampleFile
    let player: AudioPlayer
    let mode: WaveformMode
    let theme: ResolvedWaveformTheme
    let renderModel: WaveformRenderModel
    let classifyMode: Bool
    @Binding var editableOnsets: [Double]
    @Binding var loopRange: ClosedRange<Double>?
    @Binding var zoom: Double
    var scrollMode: WaveformScrollMode
    @Binding var scrollFraction: Double
    @Binding var selection: ClosedRange<Double>?
    var onWillChangeOnsets: (() -> Void)?
    var onWillChangeLoop: (() -> Void)?
    var onSelectionDragBegan: (() -> Void)?
    var onPlaybackRegionChanged: ((ClosedRange<Double>?) -> Void)?

    var body: some View {
        let active = player.loadedPath == sample.path
        WaveformView(
            mode: mode,
            theme: theme,
            model: renderModel,
            currentTime: active ? player.currentTime : 0,
            isPlaying: active && player.isPlaying,
            isActiveSample: active,
            samplePath: sample.path,
            selection: $selection,
            classifyMode: classifyMode,
            editableOnsets: $editableOnsets,
            loopRange: $loopRange,
            zoom: $zoom,
            scrollMode: scrollMode,
            scrollFraction: $scrollFraction,
            onSeek: { t in
                if player.loadedPath != sample.path {
                    player.load(url: sample.url)
                }
                player.seek(to: t)
            },
            onWillChangeOnsets: onWillChangeOnsets,
            onWillChangeLoop: onWillChangeLoop,
            onSelectionDragBegan: onSelectionDragBegan,
            onPlaybackRegionChanged: onPlaybackRegionChanged
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DetailPaneControls: View {
    let sample: SampleFile
    @Bindable var player: AudioPlayer
    @Binding var selection: ClosedRange<Double>?
    let sliceOnsets: [Double]
    var onFilesChanged: () -> Void
    var onStatus: (String) -> Void

    @State private var fadeMs: Double = 5
    @State private var normalizeTarget: Double = -0.3
    @State private var errorMessage: String?
    @AppStorage("resumeFromStopPosition") private var resumeFromStopPosition = false
    @AppStorage("playbackFXLocked") private var playbackFXLocked = false

    private var sampleDuration: Double {
        if player.loadedPath == sample.path, player.duration > 0 {
            return player.duration
        }
        return sample.duration ?? 0
    }

    var body: some View {
        VStack(spacing: 6) {
            playbackScrubber
            FlowLayout(spacing: 10, rowSpacing: 8) {
                transportControls.toolbarCluster()
                playbackFXControls.toolbarCluster()
                trimControls.toolbarCluster()
                sliceControls.toolbarCluster()
                normalizeControls.toolbarCluster()
                revealInFinderButton.toolbarCluster()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Edit failed", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var transportControls: some View {
        HStack(spacing: 14) {
            Button {
                player.togglePlay(url: sample.url)
            } label: {
                Image(systemName: player.isPlaying && player.loadedPath == sample.path
                      ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help("Play/pause (Space)")

            Toggle(isOn: $player.isLooping) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop playback (green loop braces, or selection if no loop braces)")

            Toggle(isOn: Binding(
                get: { !resumeFromStopPosition },
                set: { resumeFromStopPosition = !$0 }
            )) {
                Image(systemName: resumeFromStopPosition ? "playpause.circle" : "arrow.uturn.backward.circle")
            }
            .toggleStyle(.button)
            .help("On: resume from the playback start position (or last cursor position). Off: resume from the stopped position. Playback always returns to the file start when it reaches the end.")
            .onAppear { player.resumeFromStopPosition = resumeFromStopPosition }
            .onChange(of: resumeFromStopPosition) { _, value in
                player.resumeFromStopPosition = value
            }
        }
    }

    private var playbackFXControls: some View {
        HStack(spacing: 14) {
            playbackSpeedControl
            Button {
                playbackFXLocked.toggle()
                if playbackFXLocked {
                    player.playbackPitch = player.playbackRate
                }
            } label: {
                Image(systemName: "link")
                    .symbolVariant(playbackFXLocked ? .fill : .none)
                    .foregroundStyle(playbackFXLocked ? Color.primary : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.borderless)
            .help("Link speed and pitch for matched tape-style adjustments.")
            playbackPitchControl
            Button("Process FX") {
                runEdit { _ in
                    try AudioEditor.applyPlaybackFX(
                        url: sample.url,
                        rate: player.playbackRate,
                        pitch: player.playbackPitch
                    )
                }
            }
            .disabled(!playbackFX.isActive)
            .help("Bake current speed and pitch into a new WAV (e.g. sample_fx_s1.5_p2.wav).")
        }
    }

    private var trimControls: some View {
        HStack(spacing: 14) {
            Button("Trim Selection") {
                runEdit { try AudioEditor.trim(
                    url: sample.url,
                    start: $0!.lowerBound,
                    end: $0!.upperBound,
                    fadeMs: fadeMs,
                    playbackFX: playbackFX
                ) }
            }
            .disabled(selection == nil)

            HStack(spacing: 4) {
                Text("Fade").font(.caption).foregroundStyle(.secondary)
                TextField("ms", value: $fadeMs, format: .number)
                    .frame(width: 40)
                    .textFieldStyle(.roundedBorder)
                Text("ms").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sliceControls: some View {
        Button("Slice at Onsets") {
            runEdit { _ in try AudioEditor.slice(url: sample.url, onsets: sliceOnsets) }
        }
        .disabled(sliceOnsets.count < 2)
    }

    private var normalizeControls: some View {
        HStack(spacing: 14) {
            Button("Normalize") {
                runEdit { _ in try AudioEditor.normalize(
                    url: sample.url,
                    targetDBFS: normalizeTarget,
                    playbackFX: playbackFX
                ) }
            }
            HStack(spacing: 4) {
                TextField("dBFS", value: $normalizeTarget, format: .number)
                    .frame(width: 46)
                    .textFieldStyle(.roundedBorder)
                Text("dBFS").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var revealInFinderButton: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([sample.url])
        } label: {
            Image(systemName: "magnifyingglass.circle")
        }
        .help("Reveal in Finder")
    }

    private var playbackFX: AudioEditor.PlaybackFX {
        AudioEditor.PlaybackFX(rate: player.playbackRate, pitch: player.playbackPitch)
    }

    private var playbackSpeedControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
            PlaybackSpeedSlider(rate: linkedSpeedBinding)
            .frame(width: 88)
            Text(formatPlaybackRate(player.playbackRate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .help("Playback speed / time stretch (0.25×–4×, pitch preserved). Option-click the handle to reset to 1×. Applied to Process FX, Trim, and Normalize when not 1×.")
    }

    private var playbackPitchControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path")
                .font(.caption)
                .foregroundStyle(.secondary)
            PlaybackSpeedSlider(rate: linkedPitchBinding)
            .frame(width: 88)
            Text(formatPlaybackRate(player.playbackPitch))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .help("Pitch shift (0.25×–4×). Option-click the handle to reset to 1×. Applied to Process FX, Trim, and Normalize when not 1×.")
    }

    private var linkedSpeedBinding: Binding<Double> {
        Binding(
            get: { Double(player.playbackRate) },
            set: { value in
                let rate = Float(value)
                player.playbackRate = rate
                if playbackFXLocked {
                    player.playbackPitch = rate
                }
            }
        )
    }

    private var linkedPitchBinding: Binding<Double> {
        Binding(
            get: { Double(player.playbackPitch) },
            set: { value in
                let pitch = Float(value)
                player.playbackPitch = pitch
                if playbackFXLocked {
                    player.playbackRate = pitch
                }
            }
        )
    }

    private func formatPlaybackRate(_ rate: Float) -> String {
        let rounded = (Double(rate) * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(format: "%.0f×", rounded)
        }
        return String(format: "%.2g×", rounded)
    }

    private var playbackScrubber: some View {
        HStack(spacing: 8) {
            Text(formatTime(player.loadedPath == sample.path ? player.currentTime : 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            PlaybackScrubber(
                currentTime: player.loadedPath == sample.path ? player.currentTime : 0,
                duration: max(sampleDuration, 0.01)
            ) { t in
                if player.loadedPath != sample.path {
                    player.load(url: sample.url)
                }
                player.seek(to: t)
            }
            Text(formatTime(sampleDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s >= 60 {
            return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
        }
        return String(format: "%.2fs", s)
    }

    private func runEdit(_ operation: (ClosedRange<Double>?) throws -> URL) {
        do {
            let out = try operation(selection)
            onStatus("Created \((out.lastPathComponent))")
            onFilesChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
