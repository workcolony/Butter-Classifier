import SwiftUI

private enum ProcShellMode: String, CaseIterable, Identifiable {
    case routine = "Routine"
    case script = "Script"
    case presets = "Presets"

    var id: String { rawValue }
}

/// LUP-style PROC shell: pick a routine, edit a script chain, or run presets.
struct ProcShellView: View {
    let sample: SampleFile
    let player: AudioPlayer
    var cropRange: ClosedRange<Double>?
    @StateObject private var presetStore = ProcPresetStore()
    var onCommitted: (URL) -> Void

    private let catalog = ProcCatalog.shared
    @State private var mode: ProcShellMode = .routine
    @State private var selectedRoutineID: String = ""
    @State private var paramValues: [String: Double] = [:]
    @State private var scriptText = ProcScriptParser.defaultTemplate()
    @State private var selectedPresetID: UUID?
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var previewURL: URL?
    @State private var isRunning = false
    @State private var recents: [ProcRecent] = []
    @AppStorage("procInputGainDB") private var inputGainDB = 0.0

    private var selectedRoutine: ProcRoutine? {
        catalog.routine(id: selectedRoutineID) ?? catalog.groups.first?.routines.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            inputGainBar
            Divider()
            modeBar
            Divider()
            HStack(spacing: 0) {
                procSidebarColumn
                Divider()
                procDetailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            recents = ProcRecentStore.load()
            if selectedRoutineID.isEmpty {
                if resolvedCropRange != nil, catalog.routine(id: "crop") != nil {
                    selectedRoutineID = "crop"
                } else {
                    selectedRoutineID = catalog.groups.first?.routines.first?.id ?? ""
                }
            }
            if let recent = recents.first(where: { $0.routineID == selectedRoutineID }) {
                paramValues = recent.params
            } else {
                resetRoutineParams()
            }
            applyCropFromSelection()
            syncPresetSelection()
        }
        .onChange(of: presetStore.presets.count) { _, _ in
            syncPresetSelection()
        }
        .onChange(of: selectedRoutineID) { _, id in
            if let recent = recents.first(where: { $0.routineID == id }) {
                paramValues = recent.params
            } else {
                resetRoutineParams()
            }
            if id == "crop" {
                applyCropFromSelection()
            }
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .script, let preset = presetStore.selected {
                scriptText = ProcScriptParser.serialize(preset.steps)
            }
        }
        .alert("PROC Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("PROC")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .fixedSize()
            Text(sample.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var inputGainBar: some View {
        FlowLayout(spacing: 12, rowSpacing: 8) {
            HStack(spacing: 12) {
                Label("Input gain", systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $inputGainDB, in: -24...24, step: 1)
                    .frame(width: 140)
                Text(String(format: "%+.0f dB", inputGainDB))
                    .font(.caption.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
                Button("0 dB") { inputGainDB = 0 }
                    .controlSize(.small)
                    .disabled(inputGainDB == 0)
            }
            .toolbarCluster()

            Text("Applied before every routine or chain")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .toolbarCluster()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeBar: some View {
        Picker("Mode", selection: $mode) {
            ForEach(ProcShellMode.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var procSidebarColumn: some View {
        ZStack(alignment: .topLeading) {
            routineSidebar
                .opacity(mode == .routine ? 1 : 0)
                .allowsHitTesting(mode == .routine)
            scriptSidebar
                .opacity(mode == .script ? 1 : 0)
                .allowsHitTesting(mode == .script)
            presetSidebar
                .opacity(mode == .presets ? 1 : 0)
                .allowsHitTesting(mode == .presets)
        }
        .frame(width: 180, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
    }

    @ViewBuilder
    private var procDetailColumn: some View {
        switch mode {
        case .routine:
            routineDetail
        case .script:
            scriptDetail
        case .presets:
            presetDetail
        }
    }

    private var routineSidebar: some View {
        procSidebarShell(
            title: "Routines",
            subtitle: "Select a processing routine"
        ) {
            if catalog.groups.isEmpty {
                ContentUnavailableView("No routines", systemImage: "wand.and.stars")
            } else {
                List {
                    if !recents.isEmpty {
                        Section("Recent") {
                            ForEach(recents) { recent in
                                if let routine = catalog.routine(id: recent.routineID) {
                                    routineListButton(routine)
                                }
                            }
                        }
                    }
                    ForEach(catalog.groups) { group in
                        Section(group.label) {
                            ForEach(group.routines) { routine in
                                routineListButton(routine)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var scriptSidebar: some View {
        procSidebarShell(
            title: "Click to insert",
            subtitle: "One routine per line. Params: name=value"
        ) {
            List {
                ForEach(catalog.groups) { group in
                    Section(group.label) {
                        ForEach(group.routines) { routine in
                            Button {
                                insertRoutineLine(routine)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routine.label)
                                        .font(.caption)
                                    Text(routine.id)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var presetSidebar: some View {
        procSidebarShell(
            title: "Presets",
            subtitle: "Saved processing chains"
        ) {

            if presetStore.presets.isEmpty {
                ContentUnavailableView("No presets", systemImage: "list.bullet.rectangle")
            } else {
                List {
                    ForEach(presetStore.presets) { preset in
                        presetListButton(preset)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func procSidebarShell<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(width: 180, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func routineListButton(_ routine: ProcRoutine) -> some View {
        Button {
            selectedRoutineID = routine.id
        } label: {
            Text(routine.label)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedRoutineID == routine.id
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
    }

    private func presetListButton(_ preset: ProcPreset) -> some View {
        Button {
            selectedPresetID = preset.id
            presetStore.selectPreset(id: preset.id)
        } label: {
            Text(preset.name)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedPresetID == preset.id
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
    }

    private var routineDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let routine = selectedRoutine {
                Text(routine.label)
                    .font(.title3.weight(.semibold))

                if !routine.params.isEmpty {
                    if routine.id == "crop", let range = resolvedCropRange {
                        HStack(spacing: 8) {
                            Image(systemName: "scissors")
                                .foregroundStyle(.secondary)
                            Text("Waveform selection: \(formatCropRange(range))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("Use Selection") { applyCropFromSelection(force: true) }
                                .controlSize(.small)
                                .fixedSize()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(routine.params) { param in
                            HStack(spacing: 12) {
                                Text(param.label)
                                    .lineLimit(1)
                                    .frame(minWidth: 40, maxWidth: 90, alignment: .leading)
                                TextField("", value: binding(for: param), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                actionButtons(preview: { runRoutine(preview: true) }, commit: { runRoutine(preview: false) })
            } else {
                ContentUnavailableView("Select a routine", systemImage: "sidebar.left")
            }

            Spacer(minLength: 0)
            footerNote("Preview plays a temp file. Commit writes a new WAV next to the original.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var scriptDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROC Script")
                .font(.title3.weight(.semibold))

            TextEditor(text: $scriptText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

            HStack(spacing: 12) {
                Button("Load Preset") {
                    if let preset = presetStore.selected {
                        scriptText = ProcScriptParser.serialize(preset.steps)
                    }
                }
                .disabled(presetStore.selected == nil)

                Button("Save to Preset") {
                    do {
                        try presetStore.updateSelectedScript(scriptText)
                        statusMessage = "Saved preset script"
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .disabled(presetStore.selected == nil)
            }

            actionButtons(preview: { runScript(preview: true) }, commit: { runScript(preview: false) })
            Spacer(minLength: 0)
            footerNote("Chains run top-to-bottom. Preview uses temp files; commit writes one final WAV.")
        }
        .padding(20)
    }

    private var presetDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let preset = presetStore.selected {
                Text(preset.name)
                    .font(.title3.weight(.semibold))

                Text("\(preset.steps.count) steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(preset.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step.routineID) \(paramSummary(step.params))")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 12) {
                    Button("Edit in Script") {
                        scriptText = ProcScriptParser.serialize(preset.steps)
                        mode = .script
                    }
                    Button("Duplicate") {
                        if let id = selectedPresetID, let index = presetStore.index(of: id) {
                            presetStore.addPreset(cloning: index)
                            syncPresetSelection()
                        }
                    }
                }

                actionButtons(
                    preview: { runSelectedPreset(preview: true) },
                    commit: { runSelectedPreset(preview: false) }
                )
            } else {
                ContentUnavailableView("Select a preset", systemImage: "list.bullet.rectangle")
            }

            Spacer(minLength: 0)
            footerNote("LUP-style starter chains. Duplicate and edit in Script mode.")
        }
        .padding(20)
    }

    private func actionButtons(preview: @escaping () -> Void, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: preview) {
                Label("Preview", systemImage: "play.fill")
            }
            .disabled(isRunning)

            Button(action: commit) {
                Label("Commit", systemImage: "square.and.arrow.down")
            }
            .disabled(isRunning)

            if previewURL != nil {
                Button("Stop Preview") {
                    player.stop()
                    cleanupPreview()
                }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func footerNote(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func paramSummary(_ params: [String: Double]) -> String {
        guard !params.isEmpty else { return "" }
        return params.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    private func binding(for param: ProcParam) -> Binding<Double> {
        Binding(
            get: { paramValues[param.name] ?? param.default },
            set: { paramValues[param.name] = clamp($0, param: param) }
        )
    }

    private func clamp(_ value: Double, param: ProcParam) -> Double {
        var v = value
        if let min = param.min { v = max(min, v) }
        if let max = param.max { v = min(max, v) }
        return v
    }

    private func syncPresetSelection() {
        guard let preset = presetStore.selected else {
            selectedPresetID = nil
            return
        }
        selectedPresetID = preset.id
    }

    private func runSelectedPreset(preview: Bool) {
        let preset: ProcPreset?
        if let id = selectedPresetID {
            preset = presetStore.preset(id: id)
        } else {
            preset = presetStore.selected
        }
        guard let preset else { return }
        runPreset(preset, preview: preview)
    }

    private func insertRoutineLine(_ routine: ProcRoutine) {
        var line = routine.id
        if !routine.params.isEmpty {
            let params = routine.params
                .map { "\($0.name)=\($0.default)" }
                .joined(separator: " ")
            line += " \(params)"
        }
        if !scriptText.isEmpty && !scriptText.hasSuffix("\n") {
            scriptText += "\n"
        }
        scriptText += line + "\n"
    }

    private func resetRoutineParams() {
        guard let routine = selectedRoutine else { return }
        paramValues = Dictionary(uniqueKeysWithValues: routine.params.map { ($0.name, $0.default) })
        if routine.id == "crop" {
            applyCropFromSelection(force: true)
        }
    }

    private var resolvedCropRange: ClosedRange<Double>? {
        Self.normalizedCropRange(cropRange, duration: sample.duration)
    }

    private static func normalizedCropRange(_ range: ClosedRange<Double>?, duration: Double?) -> ClosedRange<Double>? {
        guard let range, range.upperBound > range.lowerBound else { return nil }
        let start = max(0, range.lowerBound)
        let end = duration.map { min($0, range.upperBound) } ?? range.upperBound
        guard end > start else { return nil }
        return start...end
    }

    private func applyCropFromSelection(force: Bool = false) {
        guard selectedRoutineID == "crop" else { return }
        guard let range = resolvedCropRange else {
            if force, let d = sample.duration {
                paramValues["start"] = 0
                paramValues["end"] = d
            }
            return
        }
        paramValues["start"] = range.lowerBound
        paramValues["end"] = range.upperBound
    }

    private func formatCropRange(_ range: ClosedRange<Double>) -> String {
        String(format: "%.3f – %.3f s", range.lowerBound, range.upperBound)
    }

    private func resolvedParams(for routine: ProcRoutine) -> [String: Double] {
        var out = paramValues
        for param in routine.params where out[param.name] == nil {
            out[param.name] = param.default
        }
        return out
    }

    private func runRoutine(preview: Bool) {
        guard let routine = selectedRoutine else { return }
        run(operation: {
            let params = resolvedParams(for: routine)
            let out = try ProcRunner.run(
                routine: routine,
                params: params,
                sourceURL: sample.url,
                preview: preview,
                inputGainDB: inputGainDB
            )
            if !preview {
                ProcRecentStore.record(routineID: routine.id, params: params)
                recents = ProcRecentStore.load()
            }
            return out
        }, preview: preview)
    }

    private func runScript(preview: Bool) {
        run(operation: {
            let steps = try ProcScriptParser.parse(scriptText)
            return try ProcRunner.runChain(
                steps: steps,
                sourceURL: sample.url,
                preview: preview,
                inputGainDB: inputGainDB
            )
        }, preview: preview)
    }

    private func runPreset(_ preset: ProcPreset, preview: Bool) {
        run(operation: {
            try ProcRunner.runChain(
                steps: preset.steps,
                sourceURL: sample.url,
                preview: preview,
                commitSuffix: ProcRunner.suffixFromPresetName(preset.name),
                inputGainDB: inputGainDB
            )
        }, preview: preview)
    }

    private func run(operation: @escaping () throws -> URL, preview: Bool) {
        isRunning = true
        statusMessage = preview ? "Rendering preview…" : "Committing…"
        errorMessage = nil
        cleanupPreview()

        Task { @MainActor in
            defer { isRunning = false }
            do {
                let out = try operation()
                if preview {
                    previewURL = out
                    player.load(url: out)
                    player.togglePlay(url: out)
                    statusMessage = "Preview: \(out.lastPathComponent)"
                } else {
                    statusMessage = "Wrote \(out.lastPathComponent)"
                    onCommitted(out)
                }
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = ""
            }
        }
    }

    private func cleanupPreview() {
        if let url = previewURL {
            try? FileManager.default.removeItem(at: url)
            previewURL = nil
        }
    }
}
