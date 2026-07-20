import SwiftUI

enum TagPickerMode {
    case toggle
    case addOnly
}

/// Pop-up grid for picking or filtering tags (stable layout, not inline).
struct TagPickerSheet: View {
    let title: String
    let knownTags: [String]
    let counts: [String: Int]
    let activeTags: Set<String>
    var mode: TagPickerMode = .toggle
    /// Toggle assignment on the current target (file or filter). Does not delete vocabulary.
    var onToggleTag: (String) -> Void
    /// Add a tag name to the global vocabulary without assigning it.
    var onRegisterTag: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var filterText = ""

    private var filteredTags: [String] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return knownTags }
        let lower = q.lowercased()
        return knownTags.filter { $0.localizedCaseInsensitiveContains(lower) }
    }

    private var createCandidate: String? {
        let token = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 2 else { return nil }
        guard !TagCatalog.hasExactMatch(token, in: knownTags) else { return nil }
        return token
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(14)

            Divider()

            HStack(spacing: 8) {
                TextField("search or new tag…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { submitFilterText(registerOnly: true) }
                Button("Add to List") { submitFilterText(registerOnly: true) }
                    .controlSize(.small)
                    .help("Save tag name to the picker without assigning it here")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Text("Click tags to assign/unassign this file. New names are saved to the list only.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Divider()

            if knownTags.isEmpty && createCandidate == nil {
                Text("Type a tag name above to add it to the list")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    FlowLayout(spacing: 8) {
                        if let candidate = createCandidate {
                            createTagButton(candidate)
                        }
                        ForEach(filteredTags, id: \.self) { tag in
                            tagButton(tag)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func submitFilterText(registerOnly: Bool = false) {
        let token = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 2 else { return }
        if let existing = TagCatalog.canonicalMatch(token, in: knownTags) {
            if mode == .addOnly && activeTags.contains(existing) { return }
            if !registerOnly {
                onToggleTag(existing)
            }
        } else {
            onRegisterTag(token)
        }
        filterText = ""
    }

    private func createTagButton(_ tag: String) -> some View {
        Button {
            onRegisterTag(tag)
            filterText = ""
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill")
                Text("Add \"\(tag)\" to list")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Save to vocabulary without assigning to this file")
    }

    private func tagButton(_ tag: String) -> some View {
        let active = activeTags.contains(tag)
        let count = counts[tag] ?? 0
        return Button {
            if mode == .addOnly && active { return }
            onToggleTag(tag)
        } label: {
            HStack(spacing: 5) {
                Text(tag)
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: active ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                active ? Color.accentColor.opacity(0.28) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(active ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: active ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(active ? "Remove from this file" : "Assign to this file")
    }
}

/// Compact tag editor row — does not observe the audio player.
struct SampleTagsEditor: View {
    let sample: SampleFile
    let tagTargets: [SampleFile]
    let knownTags: [String]
    let tagCounts: [String: Int]
    let tagPreset: TagZonePreset
    let tagVocabulary: TagVocabularyStore
    var suggestionRevision: Int = 0
    var onTagsChanged: () -> Void
    var onVocabularyChanged: () -> Void

    @Environment(\.modelContext) private var context
    @State private var newTagText = ""
    @State private var removeTagText = ""
    @State private var showTagPicker = false
    @State private var pickerDraftTags: Set<String> = []
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var suggestions: [TagSuggestionItem] = []

    private var bulkTagging: Bool { tagTargets.count > 1 }

    private var unionTags: [String] {
        Array(Set(tagTargets.flatMap(\.tags))).sorted()
    }

    private var displayedTags: [String] {
        bulkTagging ? unionTags : sample.tags
    }

    private var displayedSuggestions: [TagSuggestionItem] {
        suggestions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bulkTagging {
                Text("Suggestions from focused file · apply to all \(tagTargets.count) selected")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                FlowLayout(spacing: 6) {
                    ForEach(displayedTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                            if !bulkTagging {
                                Button { removeTag(tag) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                TextField(bulkTagging ? "snare, top…" : "add tags…", text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: bulkTagging ? 140 : 130)
                    .onSubmit { addTagsFromField() }
                Button(bulkTagging ? "Add All" : "Add") { addTagsFromField() }
                    .controlSize(.small)
                Button {
                    pickerDraftTags = Set(displayedTags)
                    showTagPicker = true
                } label: {
                    Label("Pick", systemImage: "tag")
                }
                .controlSize(.small)
                .help("Open tag grid")
                Button { refreshSuggestions() } label: {
                    Label("Suggest", systemImage: "sparkles")
                }
                .controlSize(.small)
                .help("Refresh auto-tag suggestions from filename, comments, and analysis")
            }
            if !displayedSuggestions.isEmpty {
                HStack(spacing: 8) {
                    Text("Suggested")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(displayedSuggestions) { item in
                            suggestionChip(item)
                        }
                    }
                    Button("Apply All") { applyAllSuggestions() }
                        .controlSize(.mini)
                }
            }
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption2).foregroundStyle(.secondary)
            }
            if bulkTagging {
                HStack(spacing: 8) {
                    TextField("remove from all…", text: $removeTagText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onSubmit { removeTagFromAll() }
                    Button("Remove from All") { removeTagFromAll() }
                        .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $showTagPicker, onDismiss: commitPickerDraft) {
            TagPickerSheet(
                title: bulkTagging ? "ADD TAGS TO \(tagTargets.count) FILES" : "TAGS",
                knownTags: knownTags,
                counts: tagCounts,
                activeTags: pickerDraftTags,
                mode: bulkTagging ? .addOnly : .toggle,
                onToggleTag: { togglePickerDraft($0) },
                onRegisterTag: { registerVocabularyTag($0) }
            )
        }
        .alert("Tag edit failed", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { Task { await reloadSuggestionsAsync() } }
        .onChange(of: sample.path) { _, _ in Task { await reloadSuggestionsAsync() } }
        .onChange(of: suggestionRevision) { _, _ in Task { await reloadSuggestionsAsync() } }
    }

    private func reloadSuggestionsAsync() async {
        let path = sample.path
        let computed = await TagSuggestionEngine.loadOrCompute(
            for: sample,
            preset: tagPreset,
            userVocabulary: tagVocabulary.tags
        )
        guard sample.path == path else { return }
        suggestions = computed
        if computed.isEmpty {
            statusMessage = "No tag suggestions for this file"
        } else if statusMessage == "No tag suggestions for this file" {
            statusMessage = ""
        }
    }

    private func togglePickerDraft(_ tag: String) {
        if pickerDraftTags.contains(tag) {
            pickerDraftTags.remove(tag)
        } else {
            pickerDraftTags.insert(tag)
        }
    }

    private func registerVocabularyTag(_ tag: String) {
        tagVocabulary.register(tag)
        onVocabularyChanged()
    }

    private func commitPickerDraft() {
        if bulkTagging {
            let toAdd = pickerDraftTags.subtracting(unionTags)
            guard !toAdd.isEmpty else { return }
            persistBulkAdd(Array(toAdd))
            return
        }
        let sorted = sample.tags.filter { pickerDraftTags.contains($0) }
            + pickerDraftTags.filter { !sample.tags.contains($0) }.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        guard sorted != sample.tags else { return }
        persistTags(sorted, refreshCatalog: true)
    }

    private func addTagsFromField() {
        let parsed = TagCatalog.parseTags(from: newTagText)
        guard !parsed.isEmpty else { return }
        for tag in parsed { tagVocabulary.register(tag) }
        onVocabularyChanged()
        if bulkTagging {
            persistBulkAdd(parsed)
        } else {
            let toAdd = parsed.filter { !sample.tags.contains($0) }
            guard !toAdd.isEmpty else { return }
            persistTags(sample.tags + toAdd, refreshCatalog: true)
        }
        newTagText = ""
    }

    private func removeTag(_ tag: String) {
        persistTags(sample.tags.filter { $0 != tag }, refreshCatalog: true)
    }

    private func removeTagFromAll() {
        let parsed = TagCatalog.parseTags(from: removeTagText)
        guard !parsed.isEmpty else { return }
        do {
            for tag in parsed {
                try LibraryScanner.removeTag(tag, from: tagTargets)
            }
            try context.save()
            removeTagText = ""
            statusMessage = "Removed \(parsed.count) tag(s) from \(tagTargets.count) files"
            onTagsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistBulkAdd(_ tags: [String]) {
        do {
            try LibraryScanner.addTags(tags, to: tagTargets)
            try context.save()
            statusMessage = "Added \(tags.count) tag(s) to \(tagTargets.count) files"
            onTagsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistTags(_ tags: [String], refreshCatalog: Bool) {
        saveTask?.cancel()
        sample.tags = tags
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            do {
                try LibraryScanner.saveTags(tags, for: sample)
                try context.save()
                if refreshCatalog { onTagsChanged() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func suggestionChip(_ item: TagSuggestionItem) -> some View {
        HStack(spacing: 4) {
            Button { applySuggestion(item.tag) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                    Text(item.tag)
                    Text("\(Int(item.confidence * 100))")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Button { dismissSuggestion(item.tag) } label: {
                Image(systemName: "xmark").font(.system(size: 7))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help(bulkTagging
            ? "From \(item.source) — click + to apply to all \(tagTargets.count) files"
            : "From \(item.source) — click + to apply")
    }

    private var suggestionTargets: [SampleFile] {
        bulkTagging ? tagTargets : [sample]
    }

    private func refreshSuggestions() {
        Task { @MainActor in
            for target in suggestionTargets {
                _ = await TagSuggestionEngine.refresh(
                    for: target,
                    preset: tagPreset,
                    userVocabulary: tagVocabulary.tags
                )
            }
            try? context.save()
            let computed = await TagSuggestionEngine.loadOrCompute(
                for: sample,
                preset: tagPreset,
                userVocabulary: tagVocabulary.tags
            )
            suggestions = computed
            if bulkTagging {
                statusMessage = computed.isEmpty
                    ? "No tag suggestions for focused file"
                    : "Refreshed \(suggestionTargets.count) files · \(computed.count) suggestion(s) shown"
            } else {
                statusMessage = computed.isEmpty
                    ? "No new tag suggestions"
                    : "\(computed.count) suggestion(s)"
            }
        }
    }

    private func applySuggestion(_ tag: String) {
        tagVocabulary.register(tag)
        onVocabularyChanged()
        do {
            for target in suggestionTargets {
                try LibraryScanner.applySuggestion(tag, for: target)
            }
            try context.save()
            suggestions.removeAll { $0.tag == tag }
            if bulkTagging {
                statusMessage = "Applied \"\(tag)\" to \(suggestionTargets.count) files"
            }
            onTagsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyAllSuggestions() {
        do {
            if bulkTagging {
                let tags = suggestions.map(\.tag)
                guard !tags.isEmpty else { return }
                try LibraryScanner.addTags(tags, to: suggestionTargets)
                for target in suggestionTargets {
                    let doc = TagSidecar.loadDocument(fromAudioPath: target.path)
                    let remaining = (doc.suggested ?? []).filter { !tags.contains($0.tag) }
                    try TagSidecar.save(tags: target.tags, suggested: remaining, audioPath: target.path)
                }
            } else {
                try LibraryScanner.applyAllSuggestions(for: sample)
            }
            try context.save()
            suggestions = []
            statusMessage = bulkTagging
                ? "Applied suggestions to \(suggestionTargets.count) files"
                : "Applied suggestions"
            onTagsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dismissSuggestion(_ tag: String) {
        do {
            for target in suggestionTargets {
                try LibraryScanner.dismissSuggestion(tag, for: target)
            }
            try context.save()
            suggestions.removeAll { $0.tag == tag }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
