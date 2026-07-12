import SwiftUI

/// LUP lobby Tag Zones / Presets editor.
struct TagZonesEditorView: View {
    @ObservedObject var store: TagZoneStore
    @Environment(\.dismiss) private var dismiss

    @State private var scrubY: Double = 0.5
    @State private var selectedZoneID: UUID?
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var newTagText = ""

    private var preset: TagZonePreset { store.selected }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 16) {
                zoneMap
                inspector
            }
            .padding(16)
            Divider()
            scrubPanel
            Divider()
            axisPanel
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("TAG ZONES")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Picker("Preset", selection: Binding(
                get: { store.selectedIndex },
                set: { store.selectPreset(at: $0) }
            )) {
                ForEach(Array(store.presets.enumerated()), id: \.offset) { i, p in
                    Text(p.name).tag(i)
                }
            }
            .labelsHidden()
            .frame(width: 180)

            if isRenaming {
                TextField("Preset name", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button("OK") { commitRename() }
            } else {
                Button("New") { store.addPreset() }
                Button("Clone") { store.addPreset(cloning: store.selectedIndex) }
                Button("Rename") {
                    renameText = preset.name
                    isRenaming = true
                }
                .disabled(preset.name == "everything")
                Button("Delete", role: .destructive) { store.deleteSelected() }
                    .disabled(preset.name == "everything")
            }
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    private var zoneMap: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEPTH MAP")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let trackH = geo.size.height - 24
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.06))
                        .frame(height: trackH * 0.08)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    ForEach(preset.zones) { zone in
                        zoneBand(zone, trackHeight: trackH, width: geo.size.width - 8)
                            .onTapGesture { selectedZoneID = zone.id }
                    }
                    // Scrub line
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width - 8, height: 2)
                        .offset(y: -scrubY * trackH)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    scrubY = min(1, max(0, 1 - v.location.y / trackH))
                                }
                        )
                }
                .overlay(alignment: .topLeading) {
                    Text("1.0 TOP")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("0.0 BTM")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
        }
        .frame(width: 280)
    }

    private func zoneBand(_ zone: TagZone, trackHeight: CGFloat, width: CGFloat) -> some View {
        let selected = selectedZoneID == zone.id
        let bandH = max(14, CGFloat(zone.h) * trackHeight)
        return VStack(alignment: .leading, spacing: 2) {
            Text(zone.tags.joined(separator: " · "))
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: width, alignment: .leading)
        .frame(height: bandH)
        .background(selected ? Color.accentColor.opacity(0.35) : Color.accentColor.opacity(0.18))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .offset(y: -CGFloat(zone.bottom) * trackHeight)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ZONE INSPECTOR")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("+ Zone") { addZone() }
                Button("Dup") { duplicateZone() }
                    .disabled(selectedZone == nil)
                Button("Del", role: .destructive) { deleteZone() }
                    .disabled(selectedZone == nil)
            }

            if let zone = selectedZone {
                HStack(spacing: 16) {
                    stepper("Y", value: zone.y) { v in updateZone { $0.y = v } }
                    stepper("H", value: zone.h) { v in updateZone { $0.h = v } }
                }
                Text("TAGS · OR'd together")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(zone.tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                            Button {
                                removeTag(tag)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8))
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                HStack {
                    TextField("add tag…", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTag() }
                    Button("Add") { addTag() }
                }
            } else {
                Text("Click a band to inspect · scrub the map to preview tag union")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrubPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SELECTS AT SCRUB · union")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack {
                Slider(value: $scrubY, in: 0...1)
                Text(String(format: "%.2f", scrubY))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(preset.tagsAtScrub(scrubY), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
            }
        }
        .padding(12)
    }

    private var axisPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("X-AXIS WINDOWS · PER-PRESET")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(TagZonePreset.axisKeys, id: \.self) { key in
                let win = preset.axisWindows[key] ?? TagAxisWindow()
                HStack(spacing: 12) {
                    Text(key.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(width: 56, alignment: .leading)
                    labeledSlider("mid", value: win.midW) { v in
                        store.updateSelected { $0.axisWindows[key, default: TagAxisWindow()].midW = v }
                    }
                    labeledSlider("end", value: win.endW) { v in
                        store.updateSelected { $0.axisWindows[key, default: TagAxisWindow()].endW = v }
                    }
                }
            }
        }
        .padding(12)
    }

    private var selectedZone: TagZone? {
        guard let id = selectedZoneID else { return nil }
        return preset.zones.first { $0.id == id }
    }

    private func stepper(_ label: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
            Button("−") { onChange(min(1, max(0.01, value - 0.02))) }
            Text(String(format: "%.2f", value))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 44)
            Button("+") { onChange(min(1, max(0.01, value + 0.02))) }
        }
    }

    private func labeledSlider(_ label: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: onChange), in: 0.01...1)
                .frame(width: 120)
        }
    }

    private func commitRename() {
        store.renameSelected(to: renameText)
        isRenaming = false
    }

    private func addZone() {
        store.updateSelected {
            $0.zones.append(TagZone(tags: ["new"], y: scrubY, h: 0.1))
        }
        selectedZoneID = store.selected.zones.last?.id
    }

    private func duplicateZone() {
        guard let z = selectedZone else { return }
        store.updateSelected {
            var copy = z
            copy.id = UUID()
            copy.y = min(1, z.y + 0.03)
            $0.zones.append(copy)
        }
        selectedZoneID = store.selected.zones.last?.id
    }

    private func deleteZone() {
        guard let id = selectedZoneID else { return }
        store.updateSelected { $0.zones.removeAll { $0.id == id } }
        selectedZoneID = nil
    }

    private func updateZone(_ mutate: (inout TagZone) -> Void) {
        guard let id = selectedZoneID else { return }
        store.updateSelected { preset in
            guard let i = preset.zones.firstIndex(where: { $0.id == id }) else { return }
            mutate(&preset.zones[i])
        }
    }

    private func addTag() {
        let t = newTagText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        updateZone { z in
            if !z.tags.contains(t) { z.tags.append(t) }
        }
        newTagText = ""
    }

    private func removeTag(_ tag: String) {
        updateZone { $0.tags.removeAll { $0 == tag } }
    }
}
