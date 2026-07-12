import SwiftUI
import SwiftData

/// Sample table isolated from the detail pane so selection/scrolling does not rebuild the waveform.
struct SampleFileTableView: View {
    let rows: [SampleFileRow]
    let sampleLookup: [PersistentIdentifier: SampleFile]
    @Binding var selection: Set<PersistentIdentifier>
    @Binding var sortOrder: [KeyPathComparator<SampleFileRow>]
    var scrollToRowID: PersistentIdentifier?
    var scrollToken: Int = 0
    var rowCount: Int = 0
    var onFocus: (PersistentIdentifier) -> Void
    var onPlay: (SampleFile) -> Void
    var onAnalyze: ([SampleFile], Bool) -> Void

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isAnalyzed ? "waveform.circle.fill" : "circle.dotted")
                        .foregroundStyle(row.isAnalyzed ? Color.accentColor : Color.secondary)
                    if row.hasClassificationEdits {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(row.name)
                }
            }
            .width(min: 220, ideal: 360)

            TableColumn("Duration", value: \.durationSort) { row in
                Text(row.durationSort >= 0 ? String(format: "%.2fs", row.durationSort) : "—")
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("BPM", value: \.bpmSort) { row in
                Text(row.bpmSort >= 0 ? String(format: "%.1f", row.bpmSort) : "—")
                    .monospacedDigit()
                    .foregroundStyle(row.hasBpmOverride ? .orange : .primary)
            }
            .width(60)

            TableColumn("LUFS", value: \.loudnessSort) { row in
                Text(row.loudnessSort > -900 ? String(format: "%.1f", row.loudnessSort) : "—")
                    .monospacedDigit()
            }
            .width(60)

            TableColumn("Kick", value: \.kickinessSort) { row in
                Text(row.kickinessSort >= 0 ? String(format: "%.0f", row.kickinessSort) : "—")
                    .monospacedDigit()
            }
            .width(50)

            TableColumn("Tags") { row in
                Text(row.tagsPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.tagsPreview)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Folder", value: \.folderName) { row in
                Text(row.folderName)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            let selected = ids.compactMap { sampleLookup[$0] }
            if selected.count == 1, let s = selected.first {
                Button(s.isAnalyzed ? "Re-analyze" : "Analyze") {
                    onAnalyze([s], s.isAnalyzed)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([s.url])
                }
            } else if selected.count > 1 {
                Button("Analyze \(selected.count) Files") {
                    onAnalyze(selected, false)
                }
                Button("Re-analyze \(selected.count) Files") {
                    onAnalyze(selected, true)
                }
                Button("Reveal \(selected.count) in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.url))
                }
            }
        } primaryAction: { ids in
            guard let id = ids.first, let sample = sampleLookup[id] else { return }
            onFocus(id)
            if ids.count == 1 {
                onPlay(sample)
            }
        }
        .overlay {
            SampleFileTableScrollHelper(
                rowIndex: scrollToRowID.flatMap { id in
                    rows.firstIndex(where: { $0.id == id })
                },
                expectedRowCount: rowCount,
                scrollToken: scrollToken
            )
        }
    }
}
