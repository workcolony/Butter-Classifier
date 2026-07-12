import SwiftUI
import SwiftData

/// LUP “crate” / LIBRARY sample finder overlay.
struct LibraryFinderView: View {
    @Query(sort: \SampleFile.name) private var allSamples: [SampleFile]
    @Environment(\.modelContext) private var context

    let player: AudioPlayer
    @ObservedObject var tagZoneStore: TagZoneStore
    @ObservedObject var tagVocabulary: TagVocabularyStore
    var restrictedFolder: String?
    var tagsCatalogRevision: Int
    var knownTags: [String]
    var onRescan: () -> Void
    var onAdopt: (SampleFile) -> Void
    var onTagsChanged: () -> Void
    var onVocabularyChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var filterText = ""
    @State private var selectedTags: Set<String> = []
    @State private var assignDraftTags: Set<String> = []
    @State private var xAxis: LibraryXAxis = .pitch
    @State private var yAxis: LibraryYAxis = .sort
    @State private var focusPath: String?
    @State private var tagZoneScrubY: Double = 0.5
    @State private var useTagZoneScrub = false
    @State private var scopeAllFolders = true
    @State private var minColumnWidth: Double = 6
    @State private var showFilterTagSheet = false
    @State private var showAssignTagSheet = false

    private enum FocusTarget: Hashable {
        case navigation
        case filter
    }

    @FocusState private var focusTarget: FocusTarget?

    private var pool: [SampleFile] {
        if scopeAllFolders { return allSamples }
        if let folder = restrictedFolder {
            return allSamples.filter { $0.watchedFolderPath == folder }
        }
        return allSamples
    }

    private var entries: [LibraryEntry] { LibraryCatalog.build(from: pool) }

    private var filtered: [LibraryEntry] {
        let text = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var tags = selectedTags
        if useTagZoneScrub {
            let scrubTags = Set(tagZoneStore.selected.tagsAtScrub(tagZoneScrubY))
            if !scrubTags.isEmpty { tags = tags.union(scrubTags) }
        }
        return entries.filter { e in
            if !text.isEmpty, !e.sample.name.lowercased().contains(text) { return false }
            if !LibraryCatalog.matchesTags(e.sample, selected: tags) { return false }
            return true
        }
    }

    private var poolTagCounts: [String: Int] {
        let _ = tagsCatalogRevision
        return Dictionary(uniqueKeysWithValues: LibraryCatalog.tagCounts(in: pool))
    }

    private var focusedEntry: LibraryEntry? {
        guard let path = focusPath else { return nil }
        return filtered.first { $0.sample.path == path }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tagFilters
            if useTagZoneScrub {
                tagZoneScrubBar
            }
            canvasStage
            previewPanel
            axisBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 1000, minHeight: 680)
        .focusable()
        .focusEffectDisabled()
        .focused($focusTarget, equals: .navigation)
        .sampleListKeyboard(
            enabled: focusTarget != .filter,
            onPrevious: { moveLibraryFocus(by: -1) },
            onNext: { moveLibraryFocus(by: 1) },
            onPlay: {
                if let entry = focusedEntry {
                    player.togglePlay(url: entry.sample.url)
                }
            },
            onAdopt: {
                if let entry = focusedEntry {
                    adopt(entry.sample)
                }
            },
            onEscape: {
                if focusTarget == .filter {
                    focusTarget = .navigation
                    return true
                }
                return false
            },
            onDismiss: { dismiss() }
        )
        .background {
            Button("") { focusTarget = .filter }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear {
            Task {
                await LibraryFeatures.ensureIndexedAsync(pool)
                await MainActor.run {
                    try? context.save()
                    if focusPath == nil, let first = sortedFilteredPaths.first {
                        focusPath = first
                    }
                    focusTarget = .navigation
                }
            }
        }
        .onChange(of: xAxis) { _, _ in
            ensureFocusStillVisible()
        }
        .onChange(of: filtered.count) { _, _ in
            ensureFocusStillVisible()
        }
        .sheet(isPresented: $showFilterTagSheet) {
            TagPickerSheet(
                title: "FILTER TAGS",
                knownTags: knownTags,
                counts: poolTagCounts,
                activeTags: selectedTags,
                mode: .toggle,
                onToggleTag: { toggleTag($0) },
                onRegisterTag: {
                    tagVocabulary.register($0)
                    onVocabularyChanged()
                }
            )
        }
        .sheet(isPresented: $showAssignTagSheet, onDismiss: commitAssignDraft) {
            if let entry = focusedEntry {
                TagPickerSheet(
                    title: "TAG SAMPLE",
                    knownTags: knownTags,
                    counts: poolTagCounts,
                    activeTags: assignDraftTags,
                    mode: .toggle,
                    onToggleTag: { tag in
                        if assignDraftTags.contains(tag) { assignDraftTags.remove(tag) }
                        else { assignDraftTags.insert(tag) }
                    },
                    onRegisterTag: {
                        tagVocabulary.register($0)
                        onVocabularyChanged()
                    }
                )
            }
        }
    }

    /// Visual left-to-right order in the canvas (matches layout sort).
    private var sortedFilteredPaths: [String] {
        filtered
            .sorted { $0.xScalar(xAxis) < $1.xScalar(xAxis) }
            .map(\.sample.path)
    }

    private func moveLibraryFocus(by delta: Int) {
        let paths = sortedFilteredPaths
        guard let next = SampleListNavigation.move(in: paths, current: focusPath, by: delta) else { return }
        focusPath = next
    }

    private func ensureFocusStillVisible() {
        let paths = sortedFilteredPaths
        guard !paths.isEmpty else {
            focusPath = nil
            return
        }
        if let focusPath, paths.contains(focusPath) { return }
        focusPath = paths[0]
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LIBRARY")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Text("sample finder — ← → navigate · Space play · Return use · ⌘F filter")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            TextField("filter by name", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .focused($focusTarget, equals: .filter)
                .help("Click to filter, or press ⌘F. Esc returns to navigation.")
            Toggle("All folders", isOn: $scopeAllFolders)
                .toggleStyle(.checkbox)
                .help("Show every watched folder, not just the sidebar selection")
            Toggle("Tag zone scrub", isOn: $useTagZoneScrub)
                .toggleStyle(.checkbox)
            Spacer()
            if !selectedTags.isEmpty {
                Button("Clear tags") { selectedTags.removeAll() }
            }
            Text("\(filtered.count) / \(pool.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
        }
        .padding(12)
    }

    private var tagFilters: some View {
        HStack(spacing: 8) {
            Text("FILTER")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            if selectedTags.isEmpty {
                Text("none")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(selectedTags.sorted(), id: \.self) { tag in
                        Button {
                            selectedTags.remove(tag)
                        } label: {
                            HStack(spacing: 3) {
                                Text(tag)
                                Image(systemName: "xmark")
                                    .font(.system(size: 7))
                            }
                            .font(.system(size: 10))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                showFilterTagSheet = true
            } label: {
                Label("Tags…", systemImage: "line.3.horizontal.decrease.circle")
            }
            .controlSize(.small)
            if !selectedTags.isEmpty {
                Button("Clear") { selectedTags.removeAll() }
                    .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { focusTarget = .navigation }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var tagZoneScrubBar: some View {
        HStack(spacing: 12) {
            Text("Zone: \(tagZoneStore.selected.name)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Slider(value: $tagZoneScrubY, in: 0...1)
            FlowLayout(spacing: 6) {
                ForEach(tagZoneStore.selected.tagsAtScrub(tagZoneScrubY), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var canvasStage: some View {
        GeometryReader { geo in
            let cells = layoutEntries(in: geo.size)
            let contentW = max(geo.size.width, CGFloat(filtered.count) * CGFloat(minColumnWidth) + 52)

            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pool.isEmpty ? "No samples in library — add a folder and rescan" : "No samples match filters")
                        .font(.system(size: 13, design: .monospaced))
                    if !pool.isEmpty {
                        Text("\(pool.count) samples indexed · try clearing tag filters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(cells, id: \.entry.id) { cell in
                                LibraryGlyphColumn(
                                    cell: cell,
                                    isFocused: focusPath == cell.entry.sample.path,
                                    isPlaying: player.loadedPath == cell.entry.sample.path && player.isPlaying
                                )
                                .id(cell.entry.sample.path)
                                .frame(width: cell.width, height: geo.size.height - 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    focusTarget = .navigation
                                    focusPath = cell.entry.sample.path
                                }
                                .onTapGesture(count: 2) {
                                    adopt(cell.entry.sample)
                                }
                            }
                        }
                        .frame(width: contentW, height: geo.size.height - 8)
                        .padding(.horizontal, 26)
                    }
                    .onChange(of: focusPath) { _, path in
                        guard let path else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(path, anchor: .center)
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    axisOverlayLabels
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var axisOverlayLabels: some View {
        HStack {
            Text("◂ \(xAxis.lowLabel)")
            Spacer()
            Text("\(xAxis.highLabel) ▸")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var previewPanel: some View {
        HStack(spacing: 16) {
            if let entry = focusedEntry {
                let _ = tagsCatalogRevision
                let s = entry.sample
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if !s.tags.isEmpty {
                        Text(s.tags.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: 280, alignment: .leading)

                HStack(spacing: 14) {
                    if let d = s.duration { previewMeta("len", String(format: "%.2fs", d)) }
                    if let b = s.effectiveBpm { previewMeta("bpm", String(format: "%.0f", b)) }
                    if let key = s.effectiveKey { previewMeta("key", key) }
                    previewMeta("pitch", String(format: "%.2f", entry.pitch))
                    previewMeta("bright", String(format: "%.2f", entry.bright))
                    previewMeta("energy", String(format: "%.2f", entry.energy))
                    if !s.isAnalyzed {
                        Text("unanalyzed")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                Button {
                    player.togglePlay(url: s.url)
                } label: {
                    Label(
                        player.isPlaying && player.loadedPath == s.path ? "Pause" : "Play",
                        systemImage: player.isPlaying && player.loadedPath == s.path ? "pause.fill" : "play.fill"
                    )
                }

                Button("Use in Browser") {
                    onAdopt(s)
                }
                .keyboardShortcut(.return, modifiers: [])

                Button {
                    assignDraftTags = Set(s.tags)
                    showAssignTagSheet = true
                } label: {
                    Label("Tags", systemImage: "tag")
                }
                .controlSize(.small)

                Text("← → · Space · Return")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Click a sample column to preview · double-click to use in the main browser")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text("column width")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: $minColumnWidth, in: 3...24)
                    .frame(width: 120)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { focusTarget = .navigation }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private func previewMeta(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    private var axisBar: some View {
        HStack(spacing: 16) {
            Text("SORT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            axisGroup(LibraryXAxis.allCases, selection: Binding(get: { xAxis }, set: { xAxis = $0 }))
            Divider().frame(height: 18)
            Text("HEIGHT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            axisGroup(LibraryYAxis.allCases, selection: Binding(get: { yAxis }, set: { yAxis = $0 }))
            Spacer()
            Text("▴ \(yAxis.label) / ▾ \(yAxis.label)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { focusTarget = .navigation }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private func axisGroup<T: Identifiable & RawRepresentable & Hashable>(_ axes: [T], selection: Binding<T>) -> some View where T.RawValue == String {
        HStack(spacing: 4) {
            ForEach(axes) { axis in
                Button {
                    selection.wrappedValue = axis
                } label: {
                    Text(axisLabel(axis))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(selection.wrappedValue.id == axis.id ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func axisLabel<T>(_ axis: T) -> String {
        if let x = axis as? LibraryXAxis { return x.label }
        if let y = axis as? LibraryYAxis { return y.label }
        return ""
    }

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) { selectedTags.remove(tag) }
        else { selectedTags.insert(tag) }
    }

    private func commitAssignDraft() {
        guard let sample = focusedEntry?.sample else { return }
        let sorted = sample.tags.filter { assignDraftTags.contains($0) }
            + assignDraftTags.filter { !sample.tags.contains($0) }.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        guard sorted != sample.tags else { return }
        do {
            try LibraryScanner.saveTags(sorted, for: sample)
            try context.save()
            onTagsChanged()
        } catch {}
    }

    private func adopt(_ sample: SampleFile) {
        onAdopt(sample)
    }

    struct LayoutCell {
        var entry: LibraryEntry
        var width: CGFloat
        var barHeight: CGFloat
    }

    private func layoutEntries(in size: CGSize) -> [LayoutCell] {
        let list = filtered
        guard !list.isEmpty else { return [] }

        let usableH = max(120, size.height - 40)
        let colW = max(CGFloat(minColumnWidth), 3)
        let sorted = list.sorted { $0.xScalar(xAxis) < $1.xScalar(xAxis) }

        return sorted.map { e in
            let yScalar = e.yScalar(yAxis, xAxis: xAxis)
            let barH = usableH * (0.16 + 0.74 * yScalar)
            var w = colW
            if focusPath == e.sample.path { w = max(w, colW * 2.2) }
            return LayoutCell(entry: e, width: w, barHeight: barH)
        }
    }
}

/// One scrollable glyph column in the library finder.
struct LibraryGlyphColumn: View {
    let cell: LibraryFinderView.LayoutCell
    let isFocused: Bool
    let isPlaying: Bool

    var body: some View {
        let e = cell.entry
        let radii = e.glyphRadii
        let pitches = e.glyphPitch
        let frameH = max(1, cell.barHeight / CGFloat(LibraryFeatures.glyphFrameCount))

        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                ForEach(0..<LibraryFeatures.glyphFrameCount, id: \.self) { i in
                    let ri = LibraryFeatures.glyphFrameCount - 1 - i
                    let r = radii[ri]
                    let p = pitches[ri]
                    let rgb = LibraryFeatures.color(forPitch: p)
                    Rectangle()
                        .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                        .opacity(0.08 + 0.92 * r)
                        .frame(height: frameH)
                }
            }
            .frame(height: cell.barHeight, alignment: .bottom)

            if isPlaying {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(y: -cell.barHeight - 4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: isFocused ? 2 : 0)
        }
        .help(e.sample.name)
    }
}
