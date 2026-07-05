import SwiftUI

/// Waveform display with playhead, onset markers, click-to-seek, and
/// drag-to-select (for trimming).
struct WaveformView: View {
    let waveform: WaveformData
    let onsets: [Double]
    let currentTime: Double
    @Binding var selection: ClosedRange<Double>?
    var onSeek: (Double) -> Void

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let duration = max(waveform.duration, 0.0001)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))

                Canvas { ctx, size in
                    drawWaveform(ctx: ctx, size: size)
                    drawOnsets(ctx: ctx, size: size, duration: duration)
                }

                if let sel = selection {
                    let x0 = CGFloat(sel.lowerBound / duration) * width
                    let x1 = CGFloat(sel.upperBound / duration) * width
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: max(1, x1 - x0))
                        .position(x: (x0 + x1) / 2, y: height / 2)
                    ForEach([x0, x1], id: \.self) { x in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 1.5)
                            .position(x: x, y: height / 2)
                    }
                }

                // Playhead
                if duration > 0.0001, currentTime > 0 {
                    let x = CGFloat(currentTime / duration) * width
                    Rectangle()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: 1.5)
                        .position(x: x, y: height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = clampedTime(x: value.location.x, width: width, duration: duration)
                        if dragStart == nil {
                            dragStart = t
                        }
                        if let start = dragStart, abs(value.translation.width) > 3 {
                            selection = min(start, t)...max(start, t)
                        }
                    }
                    .onEnded { value in
                        let t = clampedTime(x: value.location.x, width: width, duration: duration)
                        if abs(value.translation.width) <= 3 {
                            selection = nil
                            onSeek(t)
                        }
                        dragStart = nil
                    }
            )
        }
    }

    private func clampedTime(x: CGFloat, width: CGFloat, duration: Double) -> Double {
        let frac = max(0, min(1, Double(x / max(width, 1))))
        return frac * duration
    }

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        let bins = waveform.mins.count
        guard bins > 0 else { return }
        let midY = size.height / 2
        let halfH = size.height / 2 * 0.92
        var path = Path()
        let step = size.width / CGFloat(bins)
        for i in 0..<bins {
            let x = CGFloat(i) * step
            let top = midY - CGFloat(waveform.maxs[i]) * halfH
            let bottom = midY - CGFloat(waveform.mins[i]) * halfH
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: max(bottom, top + 1)))
        }
        ctx.stroke(path, with: .color(Color.accentColor.opacity(0.85)), lineWidth: max(1, step * 0.8))
    }

    private func drawOnsets(ctx: GraphicsContext, size: CGSize, duration: Double) {
        guard duration > 0 else { return }
        for onset in onsets {
            let x = CGFloat(onset / duration) * size.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(path, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}
