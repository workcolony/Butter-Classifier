import SwiftUI
import SwiftData

/// Bottom pane: waveform player and editing tools for the selected sample.
struct DetailPane: View {
    let sample: SampleFile
    @ObservedObject var player: AudioPlayer
    var onFilesChanged: () -> Void

    @State private var waveform: WaveformData = .empty
    @State private var selection: ClosedRange<Double>?
    @State private var fadeMs: Double = 5
    @State private var normalizeTarget: Double = -0.3
    @State private var statusMessage = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            header

            WaveformView(
                waveform: waveform,
                onsets: sample.onsetTimes,
                currentTime: player.loadedPath == sample.path ? player.currentTime : 0,
                selection: $selection,
                onSeek: { t in
                    if player.loadedPath != sample.path {
                        player.load(url: sample.url)
                    }
                    player.seek(to: t)
                }
            )
            .frame(minHeight: 110, maxHeight: 150)

            controls
        }
        .padding(12)
        .task(id: sample.path) {
            selection = nil
            statusMessage = ""
            errorMessage = nil
            waveform = (try? WaveformLoader.load(url: sample.url)) ?? .empty
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

    private var header: some View {
        HStack(spacing: 12) {
            Text(sample.name).font(.headline).lineLimit(1)
            if let d = sample.duration {
                metric("Duration", String(format: "%.2fs", d))
            }
            if let bpm = sample.bpm {
                metric("BPM", String(format: "%.1f", bpm))
            }
            if let lufs = sample.loudnessLUFS {
                metric("LUFS", String(format: "%.1f", lufs))
            }
            if let k = sample.kickiness {
                metric("Kick", String(format: "%.0f", k))
            }
            if let s = sample.swing8th {
                metric("Swing", String(format: "%.3f", s))
            }
            if !sample.onsetTimes.isEmpty {
                metric("Onsets", "\(sample.onsetTimes.count)")
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

    private var controls: some View {
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
            .help("Loop playback")

            Divider().frame(height: 18)

            // Trim
            Button("Trim Selection") { runEdit { try AudioEditor.trim(url: sample.url, start: $0!.lowerBound, end: $0!.upperBound, fadeMs: fadeMs) } }
                .disabled(selection == nil)
                .help("Export the selected region as a new WAV")

            HStack(spacing: 4) {
                Text("Fade").font(.caption).foregroundStyle(.secondary)
                TextField("ms", value: $fadeMs, format: .number)
                    .frame(width: 40)
                    .textFieldStyle(.roundedBorder)
                Text("ms").font(.caption).foregroundStyle(.secondary)
            }

            Divider().frame(height: 18)

            // Slice
            Button("Slice at Onsets") { runEdit { _ in try AudioEditor.slice(url: sample.url, onsets: sample.onsetTimes) } }
                .disabled(sample.onsetTimes.count < 2)
                .help("Cut the file at analyzed onsets into a _slices folder")

            Divider().frame(height: 18)

            // Normalize
            Button("Normalize") { runEdit { _ in try AudioEditor.normalize(url: sample.url, targetDBFS: normalizeTarget) } }
                .help("Peak-normalize to the target level as a new WAV")
            HStack(spacing: 4) {
                TextField("dBFS", value: $normalizeTarget, format: .number)
                    .frame(width: 46)
                    .textFieldStyle(.roundedBorder)
                Text("dBFS").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([sample.url])
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .help("Reveal in Finder")
        }
    }

    private func runEdit(_ operation: (ClosedRange<Double>?) throws -> URL) {
        do {
            let out = try operation(selection)
            statusMessage = "Created \((out.lastPathComponent))"
            onFilesChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
