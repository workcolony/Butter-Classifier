import SwiftUI
import SwiftData

/// Detail stack (waveform + tags) isolated from the file table to limit redraw scope.
struct SampleDetailStack: View {
    let sample: SampleFile
    let tagTargets: [SampleFile]
    let knownTags: [String]
    let tagCounts: [String: Int]
    let tagPreset: TagZonePreset
    @ObservedObject var tagVocabulary: TagVocabularyStore
    let suggestionRevision: Int
    let player: AudioPlayer
    let keyboardRouter: EditorKeyboardRouter
    @Binding var editorFocused: Bool
    @Binding var waveformSelection: ClosedRange<Double>?
    var onFilesChanged: () -> Void
    var onEditsChanged: (String) -> Void
    var onTagsChanged: () -> Void
    var onVocabularyChanged: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DetailPane(
                sample: sample,
                tagTargets: tagTargets,
                player: player,
                keyboardRouter: keyboardRouter,
                editorFocused: $editorFocused,
                selection: $waveformSelection,
                onFilesChanged: onFilesChanged,
                onEditsChanged: onEditsChanged
            )
            Divider()
            SampleTagsEditor(
                sample: sample,
                tagTargets: tagTargets,
                knownTags: knownTags,
                tagCounts: tagCounts,
                tagPreset: tagPreset,
                tagVocabulary: tagVocabulary,
                suggestionRevision: suggestionRevision,
                onTagsChanged: onTagsChanged,
                onVocabularyChanged: onVocabularyChanged
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
        }
        .id(sample.persistentModelID)
    }
}
