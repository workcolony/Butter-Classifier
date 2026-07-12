import SwiftUI
import AppKit

/// Waveform display with playhead, onset markers, click-to-seek, drag-to-select,
/// and LUP-style display modes (original, supersample, glass, chromagram, ribbon).
struct WaveformView: View {
    let mode: WaveformMode
    let theme: ResolvedWaveformTheme
    let model: WaveformRenderModel
    let currentTime: Double
    let isPlaying: Bool
    let isActiveSample: Bool
    let samplePath: String
    @Binding var selection: ClosedRange<Double>?
    var classifyMode: Bool = false
    @Binding var editableOnsets: [Double]
    @Binding var loopRange: ClosedRange<Double>?
    @Binding var zoom: Double
    var scrollMode: WaveformScrollMode
    @Binding var scrollFraction: Double
    var onSeek: (Double) -> Void
    var onWillChangeOnsets: (() -> Void)?
    var onWillChangeLoop: (() -> Void)?
    var onSelectionDragBegan: (() -> Void)?
    /// Called immediately when the committed waveform selection changes (before seek).
    var onPlaybackRegionChanged: ((ClosedRange<Double>?) -> Void)?

    @State private var dragStart: Double?
    /// In-progress marquee — committed to `selection` only when the drag ends.
    @State private var dragSelection: ClosedRange<Double>?
    @State private var isDraggingSelection = false
    @State private var draggingLoopEdge: LoopEdge?
    @State private var loopDragStart: Double?
    @State private var panStartFraction: Double?
    @State private var draggingOnsetIndex: Int?
    @State private var selectedOnsetIndex: Int?
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapX: CGFloat = 0
    @State private var manualScrollUntil: Date = .distantPast
    @State private var scrollLockFraction: Double?
    @State private var selectionAdjustEdge: SelectionEdge?
    @State private var previousDisplayedTime: Double = 0
    @State private var latchedPlayheadOnsetIndex: Int?
    @State private var flashingOnsetIndex: Int?
    @State private var onsetFlashUntil: Date = .distantPast

    private let onsetSnapEpsilon = 0.015
    private let onsetLatchRelease = 0.05

    private enum LoopEdge {
        case start, end
    }

    private enum SelectionEdge {
        case start, end
    }

    private var effectiveMode: WaveformMode {
        if mode.needsAnalysis && !model.hasSpectralData { return .original }
        return mode
    }

    private var displayOnsets: [Double] { editableOnsets }

    private var waveformDuration: Double {
        max(model.duration, model.waveform.duration, 0.0001)
    }

    private var maxZoom: Double {
        WaveformViewport.maxZoom(duration: waveformDuration)
    }

    private var displayedTime: Double {
        isActiveSample ? currentTime : 0
    }

    var body: some View {
        GeometryReader { geo in
            let viewportW = geo.size.width
            let height = geo.size.height
            let duration = max(model.duration, model.waveform.duration, 0.0001)
            let viewport = WaveformViewport(
                viewportW: viewportW,
                duration: duration,
                zoom: zoom,
                scrollFraction: scrollFraction
            )

            waveformContent(
                viewport: viewport,
                height: height,
                duration: duration
            )
            .frame(width: viewportW, height: height)
            .clipped()
            .overlay {
                WaveformWheelHandler(
                    canPanHorizontally: zoom > 1.01 && scrollMode != .none,
                    onHorizontalScroll: { delta in
                        guard zoom > 1.01, scrollMode != .none else { return }
                        guard scrollLockFraction == nil,
                              draggingOnsetIndex == nil,
                              draggingLoopEdge == nil,
                              loopDragStart == nil,
                              selectionAdjustEdge == nil
                        else { return }
                        pauseAutoReveal()
                        let maxScroll = max(1, viewport.contentW - viewportW)
                        if scrollMode == .page {
                            let page = scrollMode.step(zoom: zoom)
                            let direction: Double = delta > 0 ? -1 : 1
                            scrollFraction = scrollMode.snapFraction(
                                scrollFraction + page * direction,
                                zoom: zoom
                            )
                        } else {
                            let fractionDelta = Double(delta / maxScroll)
                            scrollFraction = (scrollFraction - fractionDelta).clamped(to: 0...1)
                        }
                    },
                    onZoom: { delta, mouseX in
                        guard scrollLockFraction == nil,
                              draggingOnsetIndex == nil,
                              draggingLoopEdge == nil,
                              loopDragStart == nil
                        else { return }
                        pauseAutoReveal()
                        let oldZoom = zoom
                        let step = Double(delta) * 0.22
                        let newZoom = (zoom + step).clamped(to: WaveformViewport.minZoom...maxZoom)
                        guard abs(newZoom - oldZoom) > 0.0001 else { return }
                        scrollFraction = scrollFractionZoomedToCursor(
                            mouseX: mouseX,
                            viewportW: viewportW,
                            oldZoom: oldZoom,
                            newZoom: newZoom,
                            scrollFraction: scrollFraction
                        )
                        zoom = newZoom
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .simultaneousGesture(panGesture(viewport: viewport))
            .animation(nil, value: scrollFraction)
            .onChange(of: currentTime) { _, newTime in
                guard isActiveSample else { return }
                if classifyMode, !isOnsetEditLocked {
                    updatePlayheadOnsetHighlight(from: previousDisplayedTime, to: newTime)
                }
                previousDisplayedTime = newTime
                if isPlaying, shouldAutoReveal {
                    revealVisibleContent(viewport: viewport, duration: duration)
                }
            }
            .onAppear {
                previousDisplayedTime = displayedTime
                latchedPlayheadOnsetIndex = nearestOnsetIndex(
                    atTime: displayedTime,
                    maxDistance: onsetSnapEpsilon
                )
            }
            .onChange(of: selection) { _, _ in
                if shouldAutoReveal {
                    revealVisibleContent(viewport: viewport, duration: duration)
                }
            }
        }
    }

    private var isOnsetEditLocked: Bool {
        scrollLockFraction != nil
            || draggingOnsetIndex != nil
            || draggingLoopEdge != nil
            || loopDragStart != nil
            || isDraggingSelection
    }

    private var displayedSelection: ClosedRange<Double>? {
        dragSelection ?? selection
    }

    /// Follow playhead/selection while editing, except during drags or manual panning.
    private var shouldAutoReveal: Bool {
        guard zoom > 1.02 else { return false }
        guard isActiveSample else { return false }
        guard !isOnsetEditLocked else { return false }
        if Date() < manualScrollUntil { return false }
        return true
    }

    /// Freeze horizontal scroll only while dragging onsets or loop markers.
    private func lockScroll() {
        if scrollLockFraction == nil {
            scrollLockFraction = scrollFraction
        }
        if let locked = scrollLockFraction, abs(scrollFraction - locked) > 0.0001 {
            scrollFraction = locked
        }
        panStartFraction = nil
    }

    private func releaseOnsetEditLock() {
        scrollLockFraction = nil
        panStartFraction = nil
    }

    private func pauseAutoReveal(for seconds: TimeInterval = 0.6) {
        manualScrollUntil = Date().addingTimeInterval(seconds)
    }

    private func resolvedPlayheadOnsetIndex(at time: Double) -> Int? {
        if let latched = latchedPlayheadOnsetIndex,
           displayOnsets.indices.contains(latched),
           abs(displayOnsets[latched] - time) < onsetLatchRelease {
            return latched
        }
        return nearestOnsetIndex(
            atTime: time,
            maxDistance: isPlaying ? 0.035 : onsetSnapEpsilon
        )
    }

    private func nearestOnsetIndex(atTime time: Double, maxDistance: Double) -> Int? {
        var best: (idx: Int, dist: Double)?
        for (index, onset) in displayOnsets.enumerated() {
            let dist = abs(onset - time)
            if dist <= maxDistance, best == nil || dist < best!.dist {
                best = (index, dist)
            }
        }
        return best?.idx
    }

    private func updatePlayheadOnsetHighlight(from oldTime: Double, to newTime: Double) {
        if flashingOnsetIndex != nil, Date() >= onsetFlashUntil {
            flashingOnsetIndex = nil
        }

        guard abs(oldTime - newTime) > 0.0001 else { return }

        if isPlaying {
            for (index, onset) in displayOnsets.enumerated() {
                let crossedForward = oldTime < onset - 0.001 && newTime >= onset - 0.001
                let crossedBackward = oldTime > onset + 0.001 && newTime <= onset + 0.001
                if crossedForward || crossedBackward {
                    if latchedPlayheadOnsetIndex != index { latchedPlayheadOnsetIndex = index }
                    if flashingOnsetIndex != index { flashingOnsetIndex = index }
                    onsetFlashUntil = Date().addingTimeInterval(0.2)
                    return
                }
            }
            if let latched = latchedPlayheadOnsetIndex,
               displayOnsets.indices.contains(latched),
               abs(displayOnsets[latched] - newTime) < onsetLatchRelease {
                return
            }
            let nearest = nearestOnsetIndex(atTime: newTime, maxDistance: 0.035)
            if latchedPlayheadOnsetIndex != nearest { latchedPlayheadOnsetIndex = nearest }
        } else {
            let nearest = nearestOnsetIndex(atTime: newTime, maxDistance: onsetSnapEpsilon)
            if latchedPlayheadOnsetIndex != nearest { latchedPlayheadOnsetIndex = nearest }
            if flashingOnsetIndex != nil { flashingOnsetIndex = nil }
        }
    }

    private func revealVisibleContent(viewport: WaveformViewport, duration: Double) {
        guard shouldAutoReveal else { return }

        var times = [displayedTime]
        if let sel = displayedSelection, sel.upperBound > sel.lowerBound {
            times.append(sel.lowerBound)
            times.append(sel.upperBound)
        }

        var frac = scrollFraction
        for time in times {
            let x = viewport.contentX(for: time)
            frac = scrollFractionToReveal(
                x: x,
                scrollFraction: frac,
                viewportW: viewport.viewportW,
                contentW: viewport.contentW
            )
        }
        if abs(frac - scrollFraction) > 0.0001 {
            scrollFraction = frac
        }
    }

    /// Scroll only when the playhead is off-screen — no centering, no extra movement.
    private func scrollFractionToReveal(
        x: CGFloat,
        scrollFraction: Double,
        viewportW: CGFloat,
        contentW: CGFloat
    ) -> Double {
        let maxScroll = max(0, contentW - viewportW)
        guard maxScroll > 0 else { return 0 }

        let margin = max(16, viewportW * 0.04)
        let scrollX = CGFloat(scrollFraction) * maxScroll
        let visibleEnd = scrollX + viewportW

        if x < scrollX + margin {
            return Double(max(0, x - margin) / maxScroll).clamped(to: 0...1)
        }
        if x > visibleEnd - margin {
            return Double(min(maxScroll, x - viewportW + margin) / maxScroll).clamped(to: 0...1)
        }
        return scrollFraction
    }

    /// Keep the waveform time under `mouseX` fixed while zoom changes.
    private func scrollFractionZoomedToCursor(
        mouseX: CGFloat,
        viewportW: CGFloat,
        oldZoom: Double,
        newZoom: Double,
        scrollFraction: Double
    ) -> Double {
        let oldContentW = max(viewportW, viewportW * CGFloat(oldZoom))
        let newContentW = max(viewportW, viewportW * CGFloat(newZoom))
        let oldMaxScroll = max(0, oldContentW - viewportW)
        let newMaxScroll = max(0, newContentW - viewportW)

        let clampedMouseX = mouseX.clamped(to: 0...viewportW)
        let oldScrollX = CGFloat(scrollFraction) * oldMaxScroll
        let anchorContentX = oldScrollX + clampedMouseX
        let contentFraction = anchorContentX / max(oldContentW, 1)

        guard newMaxScroll > 0 else { return 0 }
        let newScrollX = contentFraction * newContentW - clampedMouseX
        return Double(newScrollX / newMaxScroll).clamped(to: 0...1)
    }

    private func panGesture(viewport: WaveformViewport) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard zoom > 1.02, scrollMode != .none else { return }
                guard draggingOnsetIndex == nil,
                      draggingLoopEdge == nil,
                      loopDragStart == nil,
                      dragStart == nil,
                      selectionAdjustEdge == nil,
                      scrollLockFraction == nil
                else {
                    panStartFraction = nil
                    return
                }
                pauseAutoReveal()
                if panStartFraction == nil { panStartFraction = scrollFraction }
                let maxScroll = max(1, viewport.contentW - viewport.viewportW)
                let delta = Double(-value.translation.width / maxScroll)
                scrollFraction = (panStartFraction! + delta).clamped(to: 0...1)
            }
            .onEnded { _ in
                panStartFraction = nil
                guard scrollLockFraction == nil else { return }
                pauseAutoReveal()
                if scrollMode == .page {
                    scrollFraction = scrollMode.snapFraction(scrollFraction, zoom: zoom)
                }
            }
    }

    private var activeOnsetIndex: Int? {
        draggingOnsetIndex ?? selectedOnsetIndex
    }

    @ViewBuilder
    private func waveformContent(
        viewport: WaveformViewport,
        height: CGFloat,
        duration: Double
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.background)

            WaveformCanvasLayer(
                mode: effectiveMode,
                theme: theme,
                model: model,
                viewportW: viewport.viewportW,
                height: height,
                visibleStart: viewport.visibleStart,
                visibleEnd: viewport.visibleEnd,
                duration: duration,
                onsets: classifyMode ? [] : editableOnsets,
                activeOnsetIndex: classifyMode ? nil : activeOnsetIndex
            )
            .equatable()

            if let sel = displayedSelection {
                let x0 = viewport.viewportX(for: sel.lowerBound)
                let x1 = viewport.viewportX(for: sel.upperBound)
                Rectangle()
                    .fill(theme.selectionFill)
                    .frame(width: max(1, x1 - x0))
                    .position(x: (x0 + x1) / 2, y: height / 2)
                selectionEdgeHandle(x: x0, active: selectionAdjustEdge == .start, height: height)
                selectionEdgeHandle(x: x1, active: selectionAdjustEdge == .end, height: height)
            }

            if let loop = loopRange {
                let x0 = viewport.viewportX(for: loop.lowerBound)
                let x1 = viewport.viewportX(for: loop.upperBound)
                Rectangle()
                    .fill(theme.loopFill)
                    .frame(width: max(1, x1 - x0))
                    .position(x: (x0 + x1) / 2, y: height / 2)
                if classifyMode {
                    loopHandle(x: x0, edge: .start, viewport: viewport, height: height, duration: duration)
                    loopHandle(x: x1, edge: .end, viewport: viewport, height: height, duration: duration)
                } else {
                    ForEach([x0, x1], id: \.self) { x in
                        Rectangle()
                            .fill(theme.loopEdge)
                            .frame(width: 2)
                            .position(x: x, y: height / 2)
                    }
                }
            }

            if classifyMode {
                let playheadOnset = resolvedPlayheadOnsetIndex(at: displayedTime)
                let pad = max(0.02, viewport.visibleDuration * 0.05)
                ForEach(Array(displayOnsets.enumerated()), id: \.offset) { index, onset in
                    if onset >= viewport.visibleStart - pad && onset <= viewport.visibleEnd + pad {
                        onsetMarker(
                            index: index,
                            x: viewport.viewportX(for: onset),
                            height: height,
                            playheadOnsetIndex: playheadOnset,
                            flashingOnsetIndex: flashingOnsetIndex
                        )
                    }
                }
            }

            if duration > 0.0001 {
                let playheadOnset = resolvedPlayheadOnsetIndex(at: displayedTime)
                PlayheadMarker(
                    x: viewport.viewportX(for: displayedTime),
                    height: height,
                    onOnset: playheadOnset != nil,
                    color: playheadOnset != nil ? theme.playheadOnOnset : theme.playhead
                )
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if let locked = scrollLockFraction, abs(scrollFraction - locked) > 0.0001 {
                        scrollFraction = locked
                    }
                    let t = viewport.time(atViewportX: value.location.x)
                    if classifyMode {
                        let optionHeld = NSEvent.modifierFlags.contains(.option)
                        if !optionHeld {
                            let moved = hypot(value.translation.width, value.translation.height) > 4
                            if draggingOnsetIndex == nil, draggingLoopEdge == nil, moved {
                                if let idx = nearestOnsetIndex(at: value.startLocation.x, viewport: viewport) {
                                    onWillChangeOnsets?()
                                    lockScroll()
                                    draggingOnsetIndex = idx
                                } else {
                                    if loopDragStart == nil {
                                        onWillChangeLoop?()
                                        lockScroll()
                                        loopDragStart = viewport.time(atViewportX: value.startLocation.x)
                                    }
                                    if let start = loopDragStart {
                                        lockScroll()
                                        loopRange = min(start, t)...max(start, t)
                                    }
                                }
                            }
                            if let idx = draggingOnsetIndex, idx < editableOnsets.count {
                                lockScroll()
                                editableOnsets[idx] = t
                            }
                        }
                    } else {
                        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
                        if shiftHeld, let sel = displayedSelection {
                            if selectionAdjustEdge == nil {
                                selectionAdjustEdge = nearestSelectionEdge(
                                    at: value.location.x,
                                    viewport: viewport,
                                    selection: sel
                                ) ?? closerSelectionEdge(
                                    at: value.location.x,
                                    viewport: viewport,
                                    selection: sel
                                )
                            }
                            if let edge = selectionAdjustEdge {
                                adjustSelection(edge: edge, to: t, selection: sel)
                            }
                        } else {
                            selectionAdjustEdge = nil
                            let moved = hypot(value.translation.width, value.translation.height)
                            if dragStart == nil {
                                guard moved > 1 else { return }
                                dragStart = viewport.time(atViewportX: value.startLocation.x)
                                isDraggingSelection = true
                                dragSelection = nil
                                onSelectionDragBegan?()
                            }
                            if let start = dragStart {
                                dragSelection = min(start, t)...max(start, t)
                            }
                        }
                    }
                }
                .onEnded { value in
                    let t = viewport.time(atViewportX: value.location.x)
                    if classifyMode {
                        let isTap = abs(value.translation.width) <= 4 && abs(value.translation.height) <= 4
                        if draggingOnsetIndex != nil {
                            editableOnsets.sort()
                            selectedOnsetIndex = draggingOnsetIndex
                            releaseOnsetEditLock()
                        } else if loopDragStart != nil {
                            releaseOnsetEditLock()
                        } else if isTap {
                            let optionHeld = NSEvent.modifierFlags.contains(.option)
                            let hitIndex = nearestOnsetIndex(at: value.location.x, viewport: viewport)
                            if optionHeld, let idx = hitIndex {
                                onWillChangeOnsets?()
                                deleteOnset(at: idx)
                                selectedOnsetIndex = nil
                            } else if isDoubleClick(at: value.location.x) {
                                onWillChangeOnsets?()
                                addOnset(at: t)
                                selectedOnsetIndex = nearestOnsetIndex(at: value.location.x, viewport: viewport)
                            } else if let idx = hitIndex {
                                selectedOnsetIndex = idx
                                onSeek(editableOnsets[idx])
                            } else {
                                selectedOnsetIndex = nil
                                onSeek(t)
                            }
                        }
                        draggingOnsetIndex = nil
                        loopDragStart = nil
                    } else if selectionAdjustEdge != nil {
                        selectionAdjustEdge = nil
                        dragStart = nil
                        dragSelection = nil
                        isDraggingSelection = false
                    } else if dragStart == nil
                                || (abs(value.translation.width) <= 2 && abs(value.translation.height) <= 2) {
                        setSelection(nil)
                        dragSelection = nil
                        onSeek(t)
                        dragStart = nil
                        isDraggingSelection = false
                    } else {
                        setSelection(dragSelection)
                        dragSelection = nil
                        dragStart = nil
                        isDraggingSelection = false
                    }
                }
        )
    }

    private func setSelection(_ value: ClosedRange<Double>?) {
        selection = value
        onPlaybackRegionChanged?(value)
    }

    private func adjustSelection(edge: SelectionEdge, to time: Double, selection sel: ClosedRange<Double>) {
        let minGap = 0.005
        switch edge {
        case .start:
            let newStart = min(time, sel.upperBound - minGap)
            setSelection(newStart...sel.upperBound)
        case .end:
            let newEnd = max(time, sel.lowerBound + minGap)
            setSelection(sel.lowerBound...newEnd)
        }
    }

    private func nearestSelectionEdge(
        at viewportX: CGFloat,
        viewport: WaveformViewport,
        selection sel: ClosedRange<Double>
    ) -> SelectionEdge? {
        let threshold = max(16, viewport.viewportW * 0.03)
        let x0 = viewport.viewportX(for: sel.lowerBound)
        let x1 = viewport.viewportX(for: sel.upperBound)
        let d0 = abs(viewportX - x0)
        let d1 = abs(viewportX - x1)
        if d0 <= threshold, d1 <= threshold { return d0 <= d1 ? .start : .end }
        if d0 <= threshold { return .start }
        if d1 <= threshold { return .end }
        return nil
    }

    private func closerSelectionEdge(
        at viewportX: CGFloat,
        viewport: WaveformViewport,
        selection sel: ClosedRange<Double>
    ) -> SelectionEdge {
        let x0 = viewport.viewportX(for: sel.lowerBound)
        let x1 = viewport.viewportX(for: sel.upperBound)
        return abs(viewportX - x0) <= abs(viewportX - x1) ? .start : .end
    }

    private func selectionEdgeHandle(x: CGFloat, active: Bool, height: CGFloat) -> some View {
        Rectangle()
            .fill(theme.selectionEdge.opacity(active ? 1 : 0.9))
            .frame(width: active ? 4 : 2, height: height * 0.85)
            .position(x: x, y: height / 2)
    }

    private func onsetHitThreshold(viewportW: CGFloat) -> CGFloat {
        max(5, min(8, viewportW * 0.012))
    }

    private func nearestOnsetIndex(at viewportX: CGFloat, viewport: WaveformViewport) -> Int? {
        let threshold = onsetHitThreshold(viewportW: viewport.viewportW)
        var best: (idx: Int, dist: CGFloat)?
        for (index, onset) in displayOnsets.enumerated() {
            let ox = viewport.viewportX(for: onset)
            let dist = abs(ox - viewportX)
            if dist <= threshold, best == nil || dist < best!.dist {
                best = (index, dist)
            }
        }
        return best?.idx
    }

    private func isDoubleClick(at x: CGFloat, now: Date = Date()) -> Bool {
        let interval = now.timeIntervalSince(lastTapTime)
        let isDouble = interval > 0.05 && interval < 0.45 && abs(x - lastTapX) < 14
        lastTapTime = now
        lastTapX = x
        return isDouble
    }

    private func addOnset(at time: Double) {
        let epsilon = 0.01
        guard !editableOnsets.contains(where: { abs($0 - time) < epsilon }) else { return }
        editableOnsets.append(time)
        editableOnsets.sort()
    }

    private func deleteOnset(at index: Int) {
        guard editableOnsets.indices.contains(index) else { return }
        editableOnsets.remove(at: index)
    }

    private func onsetMarker(
        index: Int,
        x: CGFloat,
        height: CGFloat,
        playheadOnsetIndex: Int?,
        flashingOnsetIndex: Int?
    ) -> some View {
        let isActive = activeOnsetIndex == index
        let playheadHere = playheadOnsetIndex == index
        let flashing = flashingOnsetIndex == index && Date() < onsetFlashUntil
        return Rectangle()
            .fill(playheadHere ? theme.onsetPlayhead : (isActive ? theme.onsetActive : theme.onset))
            .frame(width: playheadHere ? 4 : (isActive ? 5 : 3), height: height)
            .opacity(flashing ? 0.45 : 1)
            .position(x: x, y: height / 2)
    }

    private func loopHandle(
        x: CGFloat,
        edge: LoopEdge,
        viewport: WaveformViewport,
        height: CGFloat,
        duration: Double
    ) -> some View {
        Rectangle()
            .fill(theme.loopEdge)
            .frame(width: 8, height: height * 0.7)
            .contentShape(Rectangle())
            .position(x: x, y: height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if draggingLoopEdge == nil {
                            onWillChangeLoop?()
                        }
                        lockScroll()
                        draggingLoopEdge = edge
                        let t = viewport.time(atViewportX: value.location.x)
                        guard var loop = loopRange else { return }
                        switch edge {
                        case .start: loop = min(t, loop.upperBound - 0.01)...loop.upperBound
                        case .end: loop = loop.lowerBound...max(t, loop.lowerBound + 0.01)
                        }
                        loopRange = loop
                    }
                    .onEnded { _ in
                        draggingLoopEdge = nil
                        releaseOnsetEditLock()
                    }
            )
    }
}

private struct PlayheadMarker: View {
    let x: CGFloat
    let height: CGFloat
    var onOnset: Bool = false
    var color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: onOnset ? 2.5 : 1.5, height: height)
            .position(x: x, y: height / 2)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
