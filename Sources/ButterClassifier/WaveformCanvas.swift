import SwiftUI

/// Scroll/zoom math and viewport coordinate conversion for the waveform editor.
struct WaveformViewport: Equatable {
    let viewportW: CGFloat
    let duration: Double
    let zoom: Double
    let scrollFraction: Double

    var contentW: CGFloat { max(viewportW, viewportW * CGFloat(zoom)) }
    var maxScroll: CGFloat { max(0, contentW - viewportW) }
    var scrollX: CGFloat { CGFloat(min(max(scrollFraction, 0), 1)) * maxScroll }
    var visibleStart: Double { Double(scrollX / max(contentW, 1)) * duration }
    var visibleDuration: Double { Double(viewportW / max(contentW, 1)) * duration }
    var visibleEnd: Double { min(duration, visibleStart + visibleDuration) }

    static let minZoom: Double = 1
    /// Minimum max-zoom even for very short clips.
    static let maxZoomFloor: Double = 128
    /// Hard cap so content width stays practical for rendering/panning.
    static let maxZoomCap: Double = 4096
    /// Visible window at full zoom (~250 ms).
    static let maxZoomTargetVisibleSeconds: Double = 0.25

    /// Maximum horizontal zoom for a clip of the given duration.
    static func maxZoom(duration: Double) -> Double {
        guard duration.isFinite, duration > maxZoomTargetVisibleSeconds else {
            return maxZoomFloor
        }
        let needed = ceil(duration / maxZoomTargetVisibleSeconds)
        return min(maxZoomCap, max(maxZoomFloor, needed))
    }

    func contentX(for time: Double) -> CGFloat {
        CGFloat(time / max(duration, 0.0001)) * contentW
    }

    func viewportX(for time: Double) -> CGFloat {
        contentX(for: time) - scrollX
    }

    func time(atViewportX x: CGFloat) -> Double {
        let contentX = scrollX + x
        let frac = max(0, min(1, Double(contentX / max(contentW, 1))))
        return frac * duration
    }
}

/// Cached waveform bitmap — only redraws when the visible window or model changes.
struct WaveformCanvasLayer: View, Equatable {
    let mode: WaveformMode
    let theme: ResolvedWaveformTheme
    let model: WaveformRenderModel
    let viewportW: CGFloat
    let height: CGFloat
    let visibleStart: Double
    let visibleEnd: Double
    let duration: Double
    let onsets: [Double]
    let activeOnsetIndex: Int?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode
            && lhs.theme == rhs.theme
            && lhs.model == rhs.model
            && lhs.viewportW == rhs.viewportW
            && lhs.height == rhs.height
            && lhs.visibleStart == rhs.visibleStart
            && lhs.visibleEnd == rhs.visibleEnd
            && lhs.duration == rhs.duration
            && lhs.onsets == rhs.onsets
            && lhs.activeOnsetIndex == rhs.activeOnsetIndex
    }

    var body: some View {
        Canvas { ctx, size in
            switch mode {
            case .original, .supersample:
                Self.drawClassicWaveform(
                    ctx: ctx,
                    size: size,
                    theme: theme,
                    model: model,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    duration: duration,
                    filled: true,
                    detailed: mode == .supersample
                )
            case .glass:
                Self.drawGlassWaveform(
                    ctx: ctx,
                    size: size,
                    theme: theme,
                    model: model,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    duration: duration
                )
            case .chromagram:
                Self.drawChromagram(
                    ctx: ctx,
                    size: size,
                    theme: theme,
                    model: model,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    duration: duration
                )
            case .ribbon:
                Self.drawRibbon(
                    ctx: ctx,
                    size: size,
                    theme: theme,
                    model: model,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    duration: duration
                )
            }
            if !onsets.isEmpty {
                Self.drawOnsets(
                    ctx: ctx,
                    size: size,
                    theme: theme,
                    onsets: onsets,
                    activeIndex: activeOnsetIndex,
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd,
                    duration: duration
                )
            }
        }
        .drawingGroup()
    }

    // MARK: - Drawing

    private static func timeToX(_ time: Double, size: CGSize, visibleStart: Double, visibleEnd: Double) -> CGFloat {
        let span = max(visibleEnd - visibleStart, 0.0001)
        return CGFloat((time - visibleStart) / span) * size.width
    }

    private static func drawClassicWaveform(
        ctx: GraphicsContext,
        size: CGSize,
        theme: ResolvedWaveformTheme,
        model: WaveformRenderModel,
        visibleStart: Double,
        visibleEnd: Double,
        duration: Double,
        filled: Bool,
        detailed: Bool,
        fillOpacityOverride: Double? = nil
    ) {
        let bins = model.waveform.mins.count
        guard bins > 0, duration > 0 else { return }

        let startBin = max(0, min(bins - 1, Int(floor(visibleStart / duration * Double(bins)))))
        let endBin = max(startBin, min(bins - 1, Int(ceil(visibleEnd / duration * Double(bins)))))
        let count = endBin - startBin + 1
        guard count > 0 else { return }

        let midY = size.height / 2
        let halfH = size.height / 2 * 0.92
        let step = size.width / CGFloat(count)

        var envelope = Path()
        envelope.move(to: CGPoint(x: 0, y: midY))
        for (offset, i) in (startBin...endBin).enumerated() {
            let x = CGFloat(offset) * step
            let top = midY - CGFloat(model.waveform.maxs[i]) * halfH
            envelope.addLine(to: CGPoint(x: x, y: top))
        }
        for (offset, i) in (startBin...endBin).reversed().enumerated() {
            let x = CGFloat(count - 1 - offset) * step
            let bottom = midY - CGFloat(model.waveform.mins[i]) * halfH
            envelope.addLine(to: CGPoint(x: x, y: bottom))
        }
        envelope.closeSubpath()

        let fillOpacity = fillOpacityOverride
            ?? (detailed ? theme.supersampleFillOpacity : theme.waveFillOpacity)
        let strokeWidth: CGFloat = detailed ? theme.supersampleStrokeWidth : 1.5
        let strokeOpacity = detailed ? theme.supersampleStrokeOpacity : theme.waveStrokeOpacity

        if detailed && theme.showCenterLine {
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: midY))
            axis.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(
                axis,
                with: .color(theme.waveStroke.opacity(theme.centerLineOpacity)),
                style: StrokeStyle(lineWidth: 0.5, dash: [4, 6])
            )
        }

        if filled {
            ctx.fill(envelope, with: .color(theme.waveFill.opacity(fillOpacity)))
        }
        ctx.stroke(envelope, with: .color(theme.waveStroke.opacity(strokeOpacity)), lineWidth: strokeWidth)
    }

    private static func drawGlassWaveform(
        ctx: GraphicsContext,
        size: CGSize,
        theme: ResolvedWaveformTheme,
        model: WaveformRenderModel,
        visibleStart: Double,
        visibleEnd: Double,
        duration: Double
    ) {
        drawClassicWaveform(
            ctx: ctx,
            size: size,
            theme: theme,
            model: model,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            duration: duration,
            filled: true,
            detailed: false,
            fillOpacityOverride: min(theme.waveFillOpacity, 0.14)
        )

        let frames = max(model.chromaSmooth.count, model.chroma.count, model.rms.count)
        guard frames > 0, duration > 0 else { return }

        let startFrame = max(0, min(frames - 1, Int(floor(visibleStart / duration * Double(frames)))))
        let endFrame = max(startFrame, min(frames - 1, Int(ceil(visibleEnd / duration * Double(frames)))))
        let count = endFrame - startFrame + 1
        guard count > 0 else { return }

        // Dim the base so stacked translucent tints don't wash out to white when zoomed out.
        let dimRect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(dimRect), with: .color(theme.background.opacity(0.42)))

        let pixelColumns = max(1, Int(ceil(size.width)))
        let framesPerColumn = Double(count) / Double(pixelColumns)
        let densityBoost = min(3.2, max(1.0, sqrt(framesPerColumn)))
        let columnW = size.width / CGFloat(pixelColumns)

        for column in 0..<pixelColumns {
            let binStart = startFrame + Int(floor(Double(column) * framesPerColumn))
            let binEnd = min(endFrame, startFrame + Int(floor(Double(column + 1) * framesPerColumn)) - 1)
            guard binStart <= binEnd else { continue }

            let frame = dominantGlassFrame(model: model, from: binStart, through: binEnd)
            let tintOpacity = min(0.78, theme.glassTintOpacity * densityBoost)
            let x = CGFloat(column) * columnW
            let rect = CGRect(x: x, y: 0, width: max(1, columnW + 0.5), height: size.height)
            let color = glassColor(model: model, at: frame)
            ctx.fill(Path(rect), with: .color(color.opacity(tintOpacity)))
        }

        let midY = size.height / 2
        var gloss = Path()
        for column in 0..<pixelColumns {
            let binStart = startFrame + Int(floor(Double(column) * framesPerColumn))
            let binEnd = min(endFrame, startFrame + Int(floor(Double(column + 1) * framesPerColumn)) - 1)
            guard binStart <= binEnd else { continue }

            let x = pixelColumns <= 1 ? size.width / 2 : (CGFloat(column) + 0.5) / CGFloat(pixelColumns) * size.width
            let amp = peakRMS(model: model, from: binStart, through: binEnd)
            let y = midY - amp * size.height * 0.38
            if column == 0 { gloss.move(to: CGPoint(x: x, y: y)) }
            else { gloss.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(gloss, with: .color(theme.waveStroke.opacity(0.62)), lineWidth: 1.1)
    }

    private static func drawChromagram(
        ctx: GraphicsContext,
        size: CGSize,
        theme: ResolvedWaveformTheme,
        model: WaveformRenderModel,
        visibleStart: Double,
        visibleEnd: Double,
        duration: Double
    ) {
        let frames = model.chroma.count
        guard frames > 0, duration > 0 else { return }

        let startFrame = max(0, min(frames - 1, Int(floor(visibleStart / duration * Double(frames)))))
        let endFrame = max(startFrame, min(frames - 1, Int(ceil(visibleEnd / duration * Double(frames)))))
        let count = endFrame - startFrame + 1
        guard count > 0 else { return }

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.background))

        let rows = 12
        let rowH = size.height / CGFloat(rows)
        drawChromaPitchGrid(ctx: ctx, size: size, rows: rows, theme: theme)

        let pixelColumns = max(1, Int(ceil(size.width)))
        let framesPerColumn = Double(count) / Double(pixelColumns)
        let columnW = size.width / CGFloat(pixelColumns)

        for column in 0..<pixelColumns {
            let binStart = startFrame + Int(floor(Double(column) * framesPerColumn))
            let binEnd = min(endFrame, startFrame + Int(floor(Double(column + 1) * framesPerColumn)) - 1)
            guard binStart <= binEnd else { continue }

            let energies = aggregatedChromaColumn(model: model, from: binStart, through: binEnd)
            let normalized = normalizedChromaColumn(energies)
            let x = CGFloat(column) * columnW
            let rectW = max(1, columnW + 0.5)

            for pitch in 0..<rows {
                let strength = normalized[pitch]
                guard strength >= 0.16 else { continue }

                let y = size.height - CGFloat(pitch + 1) * rowH
                let rect = CGRect(x: x, y: y, width: rectW, height: rowH + 0.5)
                let rgb = chromaHeatColor(pitchClass: pitch, strength: strength)
                let alpha = chromaHeatAlpha(strength: strength)
                ctx.fill(
                    Path(rect),
                    with: .color(Color(red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: alpha))
                )
            }
        }

        drawChromaDominantContour(
            ctx: ctx,
            size: size,
            theme: theme,
            model: model,
            startFrame: startFrame,
            endFrame: endFrame,
            pixelColumns: pixelColumns,
            framesPerColumn: framesPerColumn
        )

        drawChromaAmplitudeOverlay(
            ctx: ctx,
            size: size,
            theme: theme,
            model: model,
            startFrame: startFrame,
            endFrame: endFrame,
            pixelColumns: pixelColumns,
            framesPerColumn: framesPerColumn
        )
    }

    private static func drawChromaPitchGrid(
        ctx: GraphicsContext,
        size: CGSize,
        rows: Int,
        theme: ResolvedWaveformTheme
    ) {
        let rowH = size.height / CGFloat(rows)
        var grid = Path()
        for row in 1..<rows {
            let y = CGFloat(row) * rowH
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(
            grid,
            with: .color(theme.waveStroke.opacity(0.10)),
            style: StrokeStyle(lineWidth: 0.5)
        )
    }

    private static func drawChromaDominantContour(
        ctx: GraphicsContext,
        size: CGSize,
        theme: ResolvedWaveformTheme,
        model: WaveformRenderModel,
        startFrame: Int,
        endFrame: Int,
        pixelColumns: Int,
        framesPerColumn: Double
    ) {
        let rows = 12
        var contour = Path()
        for column in 0..<pixelColumns {
            let binStart = startFrame + Int(floor(Double(column) * framesPerColumn))
            let binEnd = min(endFrame, startFrame + Int(floor(Double(column + 1) * framesPerColumn)) - 1)
            guard binStart <= binEnd else { continue }

            let pitch = dominantPitchClass(model: model, from: binStart, through: binEnd)
            let x = pixelColumns <= 1 ? size.width / 2 : (CGFloat(column) + 0.5) / CGFloat(pixelColumns) * size.width
            let y = size.height - (CGFloat(pitch) + 0.5) / CGFloat(rows) * size.height
            if column == 0 { contour.move(to: CGPoint(x: x, y: y)) }
            else { contour.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(
            contour,
            with: .color(theme.playhead.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )
    }

    private static func drawChromaAmplitudeOverlay(
        ctx: GraphicsContext,
        size: CGSize,
        theme: ResolvedWaveformTheme,
        model: WaveformRenderModel,
        startFrame: Int,
        endFrame: Int,
        pixelColumns: Int,
        framesPerColumn: Double
    ) {
        guard !model.rms.isEmpty else { return }

        var envelope = Path()
        for column in 0..<pixelColumns {
            let binStart = startFrame + Int(floor(Double(column) * framesPerColumn))
            let binEnd = min(endFrame, startFrame + Int(floor(Double(column + 1) * framesPerColumn)) - 1)
            guard binStart <= binEnd else { continue }

            let x = pixelColumns <= 1 ? size.width / 2 : (CGFloat(column) + 0.5) / CGFloat(pixelColumns) * size.width
            let amp = peakRMS(model: model, from: binStart, through: binEnd)
            let y = size.height * (0.96 - amp * 0.18)
            if column == 0 { envelope.move(to: CGPoint(x: x, y: y)) }
            else { envelope.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(
            envelope,
            with: .color(theme.waveStroke.opacity(0.42)),
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
        )
    }

    private static func aggregatedChromaColumn(model: WaveformRenderModel, from start: Int, through end: Int) -> [Double] {
        var energies = Array(repeating: 0.0, count: 12)
        for frame in start...end {
            guard frame < model.chroma.count else { continue }
            let row = model.chroma[frame]
            for pitch in 0..<min(12, row.count) {
                energies[pitch] = max(energies[pitch], row[pitch])
            }
        }
        return energies
    }

    private static func normalizedChromaColumn(_ energies: [Double]) -> [Double] {
        let peak = energies.max() ?? 0
        guard peak > 0.0001 else { return energies }
        return energies.map { $0 / peak }
    }

    private static func dominantPitchClass(model: WaveformRenderModel, from start: Int, through end: Int) -> Int {
        let energies = aggregatedChromaColumn(model: model, from: start, through: end)
        var bestPitch = 0
        var bestEnergy = -Double.infinity
        for (pitch, energy) in energies.enumerated() where energy > bestEnergy {
            bestEnergy = energy
            bestPitch = pitch
        }
        return bestPitch
    }

    private static func chromaHeatColor(pitchClass: Int, strength: Double) -> (red: Double, green: Double, blue: Double) {
        let hue = Double(pitchClass) / 12
        let saturation = 0.42 + 0.48 * strength
        let lightness = 0.16 + 0.44 * strength
        return hslToRgb(h: hue, s: saturation, l: lightness)
    }

    private static func chromaHeatAlpha(strength: Double) -> Double {
        min(0.92, max(0, (strength - 0.14) / 0.86) * 0.88)
    }

    private static func chromaPitchColor(pitchClass: Int, strength: Double) -> (red: Double, green: Double, blue: Double) {
        let hue = Double(pitchClass) / 12
        return hslToRgb(h: hue, s: 0.55, l: 0.35 + 0.4 * min(1, strength))
    }

    private static func drawRibbon(
        ctx: GraphicsContext,
        size: CGSize,
        theme: ResolvedWaveformTheme,
        model: WaveformRenderModel,
        visibleStart: Double,
        visibleEnd: Double,
        duration: Double
    ) {
        let frames = max(model.spectralCentroids.count, model.rms.count)
        guard frames > 1, duration > 0 else {
            drawClassicWaveform(
                ctx: ctx,
                size: size,
                theme: theme,
                model: model,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                duration: duration,
                filled: false,
                detailed: false
            )
            return
        }

        let startFrame = max(0, min(frames - 2, Int(floor(visibleStart / duration * Double(frames)))))
        let endFrame = max(startFrame + 1, min(frames - 1, Int(ceil(visibleEnd / duration * Double(frames)))))

        let centroids = model.spectralCentroids
        let minC = model.drawStats.centroidMin
        let maxC = model.drawStats.centroidMax
        let maxR = max(model.drawStats.rmsMax, 0.001)
        let span = max(visibleEnd - visibleStart, 0.0001)

        for i in startFrame..<endFrame {
            let t0 = Double(i) / Double(frames - 1) * duration
            let t1 = Double(i + 1) / Double(frames - 1) * duration
            let x0 = CGFloat((t0 - visibleStart) / span) * size.width
            let x1 = CGFloat((t1 - visibleStart) / span) * size.width
            let c0 = (centroids[i] - minC) / (maxC - minC)
            let c1 = (centroids[min(i + 1, centroids.count - 1)] - minC) / (maxC - minC)
            let y0 = size.height * (0.88 - 0.76 * CGFloat(c0))
            let y1 = size.height * (0.88 - 0.76 * CGFloat(c1))
            let w0 = CGFloat((model.rms[safe: i] ?? 0) / maxR) * 10 + 2
            let pitch0 = LibraryFeatures.pitchScalar(fromCentroid: centroids[i])
            let rgb = LibraryFeatures.color(forPitch: pitch0)

            var segment = Path()
            segment.move(to: CGPoint(x: x0, y: y0))
            segment.addLine(to: CGPoint(x: x1, y: y1))
            ctx.stroke(
                segment,
                with: .color(Color(red: rgb.red, green: rgb.green, blue: rgb.blue).opacity(0.85)),
                style: StrokeStyle(lineWidth: w0, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private static func drawOnsets(
        ctx: GraphicsContext,
        size: CGSize,
        theme: ResolvedWaveformTheme,
        onsets: [Double],
        activeIndex: Int?,
        visibleStart: Double,
        visibleEnd: Double,
        duration: Double
    ) {
        guard duration > 0 else { return }
        let pad = max(0.02, (visibleEnd - visibleStart) * 0.02)
        for (index, onset) in onsets.enumerated() {
            guard onset >= visibleStart - pad, onset <= visibleEnd + pad else { continue }
            let x = timeToX(onset, size: size, visibleStart: visibleStart, visibleEnd: visibleEnd)
            let isActive = activeIndex == index
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            if isActive {
                ctx.stroke(
                    path,
                    with: .color(theme.onsetActiveGlow),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                ctx.stroke(
                    path,
                    with: .color(theme.onsetActiveCore),
                    style: StrokeStyle(lineWidth: 2)
                )
            } else {
                ctx.stroke(path, with: .color(theme.onset), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    private static func glassColor(model: WaveformRenderModel, at frame: Int) -> Color {
        let rgb: (red: Double, green: Double, blue: Double)
        if frame < model.chromaSmooth.count {
            let hsl = model.chromaSmooth[frame]
            let saturation = min(1, hsl.saturation * 1.28 + 0.14)
            let lightness = min(0.68, hsl.lightness * 0.72 + 0.10)
            rgb = hslToRgb(h: hsl.hue / 360, s: saturation, l: lightness)
        } else if frame < model.chroma.count, let maxPitch = model.chroma[frame].enumerated().max(by: { $0.element < $1.element })?.offset {
            rgb = chromaPitchColor(pitchClass: maxPitch, strength: 1)
        } else {
            let pitch = LibraryFeatures.pitchScalar(fromCentroid: model.spectralCentroids[safe: frame] ?? 2000)
            rgb = LibraryFeatures.color(forPitch: pitch)
        }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func dominantGlassFrame(model: WaveformRenderModel, from start: Int, through end: Int) -> Int {
        guard start < end else { return start }
        var bestFrame = start
        var bestRMS = -Double.infinity
        for frame in start...end {
            let rms = model.rms[safe: frame] ?? 0
            if rms > bestRMS {
                bestRMS = rms
                bestFrame = frame
            }
        }
        if bestRMS > 0 { return bestFrame }

        var bestChroma = -Double.infinity
        for frame in start...end {
            guard frame < model.chromaSmooth.count else { continue }
            let strength = model.chromaSmooth[frame].saturation + model.chromaSmooth[frame].lightness
            if strength > bestChroma {
                bestChroma = strength
                bestFrame = frame
            }
        }
        if bestChroma > 0 { return bestFrame }

        return start + (end - start) / 2
    }

    private static func peakRMS(model: WaveformRenderModel, from start: Int, through end: Int) -> CGFloat {
        guard !model.rms.isEmpty else { return 0.2 }
        let maxR = max(model.drawStats.rmsMax, 0.001)
        var peak = 0.0
        for frame in start...end {
            peak = max(peak, model.rms[safe: frame] ?? 0)
        }
        return CGFloat(peak / maxR)
    }

    private static func hslToRgb(h: Double, s: Double, l: Double) -> (red: Double, green: Double, blue: Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue2rgb(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        return (hue2rgb(h + 1/3), hue2rgb(h), hue2rgb(h - 1/3))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private extension LibraryFeatures {
    static func pitchScalar(fromCentroid hz: Double) -> Double {
        let norm = (log(max(1, hz)) - log(200)) / (log(8000) - log(200))
        return min(1, max(0, norm))
    }
}
