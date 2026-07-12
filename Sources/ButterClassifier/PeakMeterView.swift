import SwiftUI

struct PlaybackMeterChannel: Equatable {
    var peakDB: Float = -80
    var rmsDB: Float = -80
}

struct PlaybackMeterLevels: Equatable {
    var left = PlaybackMeterChannel()
    var right = PlaybackMeterChannel()
}

/// Stereo combo VU + peak meter (−60…0 dBFS).
struct PeakMeterView: View {
    let levels: PlaybackMeterLevels

    private let floorDB: Float = -60
    /// 18 segments ≈ 3.3 dB per step.
    private let segmentCount = 18

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                channelRow(label: "L", channel: levels.left)
                channelRow(label: "R", channel: levels.right)
            }
            Text(formatDB(maxPeak))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityLabel(accessibilityText)
    }

    private var maxPeak: Float {
        max(levels.left.peakDB, levels.right.peakDB)
    }

    private var accessibilityText: String {
        "Left peak \(formatDB(levels.left.peakDB)), right peak \(formatDB(levels.right.peakDB))"
    }

    private func channelRow(label: String, channel: PlaybackMeterChannel) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .trailing)
            meterBar(peakDB: channel.peakDB, rmsDB: channel.rmsDB)
        }
    }

    private func meterBar(peakDB: Float, rmsDB: Float) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<segmentCount, id: \.self) { index in
                let threshold = segmentThreshold(index)
                segmentCell(
                    index: index,
                    threshold: threshold,
                    peakDB: peakDB,
                    rmsDB: rmsDB
                )
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func segmentCell(index: Int, threshold: Float, peakDB: Float, rmsDB: Float) -> some View {
        let peakLit = peakDB >= threshold
        let vuLit = rmsDB >= threshold
        return ZStack {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.10))
            if vuLit {
                RoundedRectangle(cornerRadius: 1)
                    .fill(vuColor(index: index))
                    .opacity(0.55)
            }
            if peakLit {
                RoundedRectangle(cornerRadius: 1)
                    .fill(peakColor(index: index))
            }
        }
        .frame(width: 4, height: 10)
    }

    private func segmentThreshold(_ index: Int) -> Float {
        let step = (0 - floorDB) / Float(segmentCount)
        return floorDB + step * Float(index + 1)
    }

    private func vuColor(index: Int) -> Color {
        let ratio = Float(index + 1) / Float(segmentCount)
        if ratio > 0.78 { return .orange }
        if ratio > 0.55 { return .yellow.opacity(0.9) }
        return .green.opacity(0.85)
    }

    private func peakColor(index: Int) -> Color {
        let ratio = Float(index + 1) / Float(segmentCount)
        if ratio > 0.88 { return .red }
        if ratio > 0.72 { return .yellow }
        return .green
    }

    private func formatDB(_ value: Float) -> String {
        if value <= floorDB + 0.5 { return "−∞" }
        return String(format: "%+.0f", value)
    }
}

/// Volume slider + stereo meters for the main window toolbar.
struct PlaybackOutputControls: View {
    @Bindable var player: AudioPlayer
    @Binding var playbackVolume: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $playbackVolume, in: 0...1)
                .frame(width: 90)
                .onChange(of: playbackVolume) { _, value in
                    player.volume = Float(value)
                }
            PeakMeterView(levels: player.meterLevels)
        }
        .help("Playback volume and output meters")
        .focusEffectDisabled()
    }
}
