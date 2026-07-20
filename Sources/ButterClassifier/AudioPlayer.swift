import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class AudioPlayer: NSObject {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var isLooping = false
    /// Play the file/region backwards (pre-reversed PCM buffer; rate stays positive).
    var isReversed = false
    /// When looping, bounce back and forth gaplessly at each boundary (requires `isLooping`).
    var isRecursiveLooping = false
    var loopRegion: ClosedRange<Double>? {
        didSet {
            let sanitized = Self.validRegion(loopRegion)
            if sanitized != loopRegion { loopRegion = sanitized }
        }
    }
    /// Waveform selection — one-shot when repeat is off; loops when repeat is on (unless green loop braces are set).
    var playbackRegion: ClosedRange<Double>? {
        didSet {
            let sanitized = Self.validRegion(playbackRegion)
            if sanitized != playbackRegion { playbackRegion = sanitized }
        }
    }
    var volume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }
    /// Time compression/expansion (0.25×–4×) with pitch preserved.
    var playbackRate: Float = 1.0 {
        didSet {
            timePitch.rate = Self.clampedRate(playbackRate)
            resyncPlaybackClock()
        }
    }
    /// Pitch shift multiplier (0.25×–4×), independent of playback rate.
    var playbackPitch: Float = 1.0 {
        didSet { timePitch.pitch = Self.pitchRatioToCents(playbackPitch) }
    }
    /// When true, resume from the paused/stopped position. When false, resume from the playback anchor.
    var resumeFromStopPosition = false
    private(set) var loadedPath: String?
    private(set) var meterLevels = PlaybackMeterLevels()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private var engineFormat: AVAudioFormat?
    private var sampleRate: Double = 44_100
    private var meterFile: AVAudioFile?
    private var meterLeftPeakLinear: Float = 0
    private var meterLeftRMSLinear: Float = 0
    private var meterRightPeakLinear: Float = 0
    private var meterRightRMSLinear: Float = 0
    private var timer: Timer?
    /// Where the current playback run began, or the last user-set cursor position.
    private var playbackAnchor: Double = 0
    /// Where playback was last paused or stopped.
    private var stopPosition: Double = 0
    private var isPaused = false
    private var playbackClockStart: CFAbsoluteTime?
    private var playbackFileOrigin: Double = 0
    /// Where the currently scheduled segment ends (seconds).
    private var scheduledSegmentEnd: Double = 0
    /// Bumps on every reschedule so stale AVAudioPlayerNode completion handlers are ignored.
    private var scheduledSegmentID = 0
    /// True while a gapless `.loops` buffer is scheduled on the player node.
    private var isLoopBufferPlaying = false
    /// The region currently looping via the gapless buffer.
    private var loopBufferRegion: ClosedRange<Double>?
    /// How the active loop buffer maps elapsed time → file position.
    private var loopBufferMode: LoopBufferMode = .forward
    /// Direction / recursive flags that were used when the current buffer was scheduled.
    private var scheduledIsReversed = false
    private var scheduledIsRecursive = false
    /// Elapsed offset into the loop buffer at schedule time (for mid-region resume).
    private var loopBufferElapsedOrigin: Double = 0

    private enum LoopBufferMode {
        case forward
        case reverse
        case pingPong
    }

    /// Region to loop while repeat is engaged (green braces beat selection).
    private var loopingRegion: ClosedRange<Double>? {
        guard isLooping else { return nil }
        return loopRegion ?? playbackRegion
    }

    /// Whole-file gapless loop when repeat is on but no braces/selection are set.
    private var wholeFileLoopRegion: ClosedRange<Double>? {
        guard isLooping, loopingRegion == nil, duration > 0.001 else { return nil }
        return 0...duration
    }

    /// Active loop region (braces, selection, or whole file).
    private var activeLoopRegion: ClosedRange<Double>? {
        loopingRegion ?? wholeFileLoopRegion
    }

    /// One-shot playback of the waveform selection when repeat is off.
    private var oneShotRegion: ClosedRange<Double>? {
        guard !isLooping else { return nil }
        return playbackRegion
    }

    /// Recursive ping-pong is only meaningful while looping.
    private var effectiveRecursiveLooping: Bool {
        isLooping && isRecursiveLooping
    }

    func load(url: URL) {
        invalidateScheduledSegment()
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            try configureEngine(format: file.processingFormat)
            audioFile = file
            meterFile = try? AVAudioFile(forReading: url)
            sampleRate = file.processingFormat.sampleRate
            duration = Double(file.length) / sampleRate
            playbackAnchor = 0
            stopPosition = 0
            currentTime = 0
            loadedPath = url.path
            resetMeter()
        } catch {
            audioFile = nil
            duration = 0
            loadedPath = nil
            meterFile = nil
            resetMeter()
        }
    }

    func togglePlay(url: URL) {
        if loadedPath != url.path {
            load(url: url)
        }
        guard audioFile != nil else { return }
        if isPlaying {
            pausePlayback()
        } else {
            beginPlayback()
        }
    }

    func seek(to time: Double) {
        let t = clamp(time)
        let wasPlaying = isPlaying
        if wasPlaying {
            invalidateScheduledSegment()
            playerNode.stop()
            isPlaying = false
            playbackClockStart = nil
            stopTimer()
        }
        currentTime = t
        playbackAnchor = t
        stopPosition = t
        if wasPlaying {
            scheduleAndPlay(from: t)
        }
    }

    func stop() {
        invalidateScheduledSegment()
        playerNode.stop()
        engine.stop()
        isPlaying = false
        currentTime = 0
        playbackAnchor = 0
        stopPosition = 0
        isPaused = false
        duration = 0
        loadedPath = nil
        audioFile = nil
        meterFile = nil
        playbackClockStart = nil
        resetMeter()
        stopTimer()
    }

    private func beginPlayback() {
        guard audioFile != nil else { return }

        invalidateScheduledSegment()
        playerNode.stop()
        stopTimer()
        isPlaying = false
        playbackClockStart = nil

        let rawStart: Double
        if isPaused {
            rawStart = resumeFromStopPosition ? stopPosition : playbackAnchor
        } else {
            rawStart = currentTime
            playbackAnchor = rawStart
        }

        isPaused = false
        let start = playbackStartTime(rawStart)
        playbackAnchor = start
        scheduleAndPlay(from: start)
    }

    private func pausePlayback() {
        invalidateScheduledSegment()
        updateCurrentTimeFromClock()
        stopPosition = currentTime
        playerNode.pause()
        isPlaying = false
        isPaused = true
        playbackClockStart = nil
        stopTimer()
        decayMeter()
    }

    /// Start time when pressing play — loops snap to the edge matching direction;
    /// one-shot selections snap into range when the cursor is outside it.
    private func playbackStartTime(_ time: Double) -> Double {
        if let region = activeLoopRegion {
            return isReversed ? region.upperBound : region.lowerBound
        }
        let t = clamp(time)
        if let region = oneShotRegion {
            if isReversed {
                if t <= region.lowerBound + 0.0005 || t > region.upperBound {
                    return region.upperBound
                }
            } else if t < region.lowerBound || t >= region.upperBound {
                return region.lowerBound
            }
            return t
        }
        if isReversed && t <= 0.0005 {
            return duration
        }
        return t
    }

    /// End time for the next forward scheduled segment starting at `start`.
    private func segmentEndTime(from start: Double) -> Double {
        if let region = loopingRegion {
            if start >= region.lowerBound && start < region.upperBound {
                return min(duration, region.upperBound)
            }
            return duration
        }
        if let region = oneShotRegion {
            return min(duration, region.upperBound)
        }
        return duration
    }

    /// Earliest file time for a reverse one-shot.
    private func segmentStartTimeGoingReverse() -> Double {
        if let region = oneShotRegion {
            return max(region.lowerBound, 0)
        }
        return 0
    }

    private func scheduleAndPlay(from startTime: Double) {
        guard audioFile != nil else { return }

        // Gapless looping (forward, reverse, or ping-pong).
        if let region = activeLoopRegion {
            scheduleLoopingRegion(region, resumeAt: startTime)
            return
        }

        isLoopBufferPlaying = false
        loopBufferRegion = nil
        loopBufferMode = .forward
        loopBufferElapsedOrigin = 0

        let start = clamp(startTime)

        if isReversed {
            scheduleReverseSegment(from: start)
            return
        }

        let end = segmentEndTime(from: start)

        if start >= end - 0.0005 {
            handleReachedSegmentEnd(from: start)
            return
        }

        scheduleForwardSegment(from: start, to: end)
    }

    private func scheduleForwardSegment(from start: Double, to end: Double) {
        guard let audioFile else { return }

        let startFrame = AVAudioFramePosition(start * sampleRate)
        let endFrame = AVAudioFramePosition(end * sampleRate)
        guard startFrame < audioFile.length, endFrame > startFrame else {
            handleReachedSegmentEnd(from: start)
            return
        }

        let frameCount = AVAudioFrameCount(min(endFrame - startFrame, audioFile.length - startFrame))
        guard frameCount > 0 else {
            handleReachedSegmentEnd(from: start)
            return
        }

        scheduledSegmentID += 1
        let segmentID = scheduledSegmentID
        scheduledSegmentEnd = end
        scheduledIsReversed = false
        scheduledIsRecursive = false

        playerNode.stop()
        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSegmentCompleted(segmentID: segmentID)
            }
        }

        startScheduledPlayback(fileOrigin: start, displayTime: start)
    }

    /// Reverse one-shot: play from `start` backward to the selection/file start.
    private func scheduleReverseSegment(from start: Double) {
        let regionStart = segmentStartTimeGoingReverse()
        let regionEnd = start
        guard regionEnd - regionStart > 0.0005 else {
            if let region = oneShotRegion {
                finishSelectionPlayback(at: region.lowerBound)
            } else {
                finishFilePlayback()
            }
            return
        }

        guard let forward = readRegionBuffer(regionStart...regionEnd),
              let reversed = reversedCopy(of: forward) else {
            finishFilePlayback()
            return
        }

        scheduledSegmentID += 1
        let segmentID = scheduledSegmentID
        scheduledSegmentEnd = regionStart
        scheduledIsReversed = true
        scheduledIsRecursive = false
        isLoopBufferPlaying = false
        loopBufferRegion = nil
        loopBufferMode = .reverse

        playerNode.stop()
        playerNode.scheduleBuffer(reversed, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSegmentCompleted(segmentID: segmentID)
            }
        }

        // Clock maps elapsed → file position decreasing from regionEnd.
        playbackFileOrigin = regionEnd
        startScheduledPlayback(fileOrigin: regionEnd, displayTime: regionEnd)
    }

    private func handleSegmentCompleted(segmentID: Int) {
        guard isPlaying, segmentID == scheduledSegmentID else { return }
        handleReachedSegmentEnd(from: scheduledSegmentEnd)
    }

    private func handleReachedSegmentEnd(from time: Double) {
        guard isPlaying else { return }
        invalidateScheduledSegment()

        if let region = activeLoopRegion {
            if effectiveRecursiveLooping {
                isReversed.toggle()
            }
            scheduleLoopingRegion(region, resumeAt: isReversed ? region.upperBound : region.lowerBound)
            return
        }
        if let region = oneShotRegion {
            let endPos = isReversed ? region.lowerBound : min(region.upperBound, duration)
            finishSelectionPlayback(at: endPos)
            return
        }
        if isReversed {
            finishFilePlayback()
            return
        }
        finishFilePlayback()
    }

    /// Schedules the loop region as a buffer the node repeats internally (gapless).
    /// Reverse loops use a pre-reversed buffer; recursive loops concatenate forward+reverse.
    private func scheduleLoopingRegion(_ region: ClosedRange<Double>, resumeAt: Double? = nil) {
        let start = clamp(region.lowerBound)
        let end = min(duration, region.upperBound)
        guard end - start > 0.0005 else {
            finishFilePlayback()
            return
        }

        let loopRegion = start...end
        let resume = resumeAt.map { min(end, max(start, $0)) } ?? (isReversed ? end : start)

        let buffer: AVAudioPCMBuffer
        let mode: LoopBufferMode
        let elapsedOrigin: Double

        if effectiveRecursiveLooping {
            guard let forward = readRegionBuffer(loopRegion),
                  let reversed = reversedCopy(of: forward),
                  let pingPong = concatenate(forward, reversed) else {
                finishFilePlayback()
                return
            }
            // Ping-pong cycle: [forward][reverse]. Pick phase from direction + position.
            let loopLen = end - start
            if isReversed {
                elapsedOrigin = loopLen + (end - resume)
            } else {
                elapsedOrigin = resume - start
            }
            guard let sliced = sliceBuffer(pingPong, fromSeconds: elapsedOrigin) else {
                finishFilePlayback()
                return
            }
            buffer = sliced
            mode = .pingPong
        } else if isReversed {
            guard let forward = readRegionBuffer(loopRegion),
                  let reversed = reversedCopy(of: forward) else {
                finishFilePlayback()
                return
            }
            elapsedOrigin = end - resume
            guard let sliced = sliceBuffer(reversed, fromSeconds: elapsedOrigin) else {
                finishFilePlayback()
                return
            }
            buffer = sliced
            mode = .reverse
        } else {
            guard let forward = readRegionBuffer(loopRegion) else {
                finishFilePlayback()
                return
            }
            elapsedOrigin = resume - start
            guard let sliced = sliceBuffer(forward, fromSeconds: elapsedOrigin) else {
                finishFilePlayback()
                return
            }
            buffer = sliced
            mode = .forward
        }

        scheduledSegmentID += 1
        scheduledSegmentEnd = end
        isLoopBufferPlaying = true
        loopBufferRegion = loopRegion
        loopBufferMode = mode
        loopBufferElapsedOrigin = elapsedOrigin
        scheduledIsReversed = isReversed
        scheduledIsRecursive = effectiveRecursiveLooping

        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionCallbackType: .dataPlayedBack) { _ in }

        startScheduledPlayback(fileOrigin: resume, displayTime: resume)
    }

    private func startScheduledPlayback(fileOrigin: Double, displayTime: Double) {
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
        isPlaying = true
        isPaused = false
        playbackFileOrigin = fileOrigin
        playbackClockStart = CFAbsoluteTimeGetCurrent()
        currentTime = displayTime
        stopPosition = displayTime
        startTimer()
    }

    private func invalidateScheduledSegment() {
        scheduledSegmentID += 1
        isLoopBufferPlaying = false
        loopBufferRegion = nil
        loopBufferMode = .forward
        loopBufferElapsedOrigin = 0
    }

    // MARK: - Buffer helpers

    private func readRegionBuffer(_ region: ClosedRange<Double>) -> AVAudioPCMBuffer? {
        guard let audioFile else { return nil }
        let start = clamp(region.lowerBound)
        let end = min(duration, region.upperBound)
        let startFrame = AVAudioFramePosition(start * sampleRate)
        let endFrame = AVAudioFramePosition(end * sampleRate)
        guard endFrame > startFrame, startFrame < audioFile.length else { return nil }

        let frameCount = AVAudioFrameCount(min(endFrame - startFrame, audioFile.length - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            return nil
        }
        do {
            audioFile.framePosition = startFrame
            try audioFile.read(into: buffer, frameCount: frameCount)
            return buffer
        } catch {
            return nil
        }
    }

    private func reversedCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        out.frameLength = buffer.frameLength
        guard let dst = out.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        for ch in 0..<channels {
            for i in 0..<frames {
                dst[ch][i] = src[ch][frames - 1 - i]
            }
        }
        return out
    }

    private func concatenate(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard a.format.isEqual(b.format) else { return nil }
        let total = a.frameLength + b.frameLength
        guard total > 0,
              let out = AVAudioPCMBuffer(pcmFormat: a.format, frameCapacity: total),
              let dst = out.floatChannelData,
              let aData = a.floatChannelData,
              let bData = b.floatChannelData else {
            return nil
        }
        out.frameLength = total
        let channels = Int(a.format.channelCount)
        let aFrames = Int(a.frameLength)
        let bFrames = Int(b.frameLength)
        for ch in 0..<channels {
            for i in 0..<aFrames { dst[ch][i] = aData[ch][i] }
            for i in 0..<bFrames { dst[ch][aFrames + i] = bData[ch][i] }
        }
        return out
    }

    /// Returns a copy of `buffer` starting at `fromSeconds` (wrapping for loop continuity via full buffer when near end).
    private func sliceBuffer(_ buffer: AVAudioPCMBuffer, fromSeconds: Double) -> AVAudioPCMBuffer? {
        let totalFrames = Int(buffer.frameLength)
        guard totalFrames > 0, let src = buffer.floatChannelData else { return nil }

        var startFrame = Int((fromSeconds * sampleRate).rounded(.towardZero))
        if startFrame <= 0 { return buffer }
        if startFrame >= totalFrames {
            startFrame = startFrame % totalFrames
        }
        if startFrame == 0 { return buffer }

        // For `.loops`, schedule from the resume point through the end, then the node
        // restarts at buffer start — so rebuild as [tail][head] to keep phase continuous.
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(totalFrames)),
              let dst = out.floatChannelData else {
            return nil
        }
        out.frameLength = AVAudioFrameCount(totalFrames)
        let channels = Int(buffer.format.channelCount)
        let tail = totalFrames - startFrame
        for ch in 0..<channels {
            for i in 0..<tail { dst[ch][i] = src[ch][startFrame + i] }
            for i in 0..<startFrame { dst[ch][tail + i] = src[ch][i] }
        }
        return out
    }

    private func configureEngine(format: AVAudioFormat) throws {
        if engineFormat?.isEqual(format) == true, engine.attachedNodes.contains(playerNode) {
            applyTimePitch()
            engine.mainMixerNode.outputVolume = volume
            if !engine.isRunning { try engine.start() }
            return
        }

        engine.stop()
        engine.reset()
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engineFormat = format
        applyTimePitch()
        engine.mainMixerNode.outputVolume = volume
        try engine.start()
    }

    private func applyTimePitch() {
        timePitch.rate = Self.clampedRate(playbackRate)
        timePitch.pitch = Self.pitchRatioToCents(playbackPitch)
    }

    private func resyncPlaybackClock() {
        guard isPlaying, playbackClockStart != nil else { return }
        updateCurrentTimeFromClock()
        playbackFileOrigin = currentTime
        playbackClockStart = CFAbsoluteTimeGetCurrent()
    }

    private func updateCurrentTimeFromClock() {
        guard let start = playbackClockStart else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * Double(Self.clampedRate(playbackRate))

        if isLoopBufferPlaying, let region = loopBufferRegion {
            let loopLen = region.upperBound - region.lowerBound
            guard loopLen > 0 else {
                currentTime = region.lowerBound
                return
            }
            let totalElapsed = loopBufferElapsedOrigin + elapsed
            switch loopBufferMode {
            case .forward:
                var rel = totalElapsed.truncatingRemainder(dividingBy: loopLen)
                if rel < 0 { rel += loopLen }
                currentTime = region.lowerBound + rel
            case .reverse:
                var rel = totalElapsed.truncatingRemainder(dividingBy: loopLen)
                if rel < 0 { rel += loopLen }
                currentTime = region.upperBound - rel
            case .pingPong:
                let cycle = loopLen * 2
                var phase = totalElapsed.truncatingRemainder(dividingBy: cycle)
                if phase < 0 { phase += cycle }
                if phase < loopLen {
                    currentTime = region.lowerBound + phase
                    // Keep UI direction in sync with the audible half-cycle.
                    if isReversed {
                        isReversed = false
                        scheduledIsReversed = false
                    }
                } else {
                    currentTime = region.upperBound - (phase - loopLen)
                    if !isReversed {
                        isReversed = true
                        scheduledIsReversed = true
                    }
                }
            }
            return
        }

        if scheduledIsReversed {
            currentTime = max(0, playbackFileOrigin - elapsed)
            return
        }

        currentTime = min(duration, playbackFileOrigin + elapsed)
    }

    private func clamp(_ time: Double) -> Double {
        max(0, min(time, duration > 0 ? duration : 0))
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }

                // Gapless loop buffer: the node repeats internally — follow region/mode edits.
                if self.isLoopBufferPlaying {
                    if self.isLooping {
                        let region = self.activeLoopRegion
                        let modeChanged = self.isReversed != self.scheduledIsReversed
                            || self.effectiveRecursiveLooping != self.scheduledIsRecursive
                        if let region, self.loopRegionChanged(region) || modeChanged {
                            let wantReversed = self.isReversed
                            self.updateCurrentTimeFromClock()
                            let resumeAt = self.currentTime
                            self.invalidateScheduledSegment()
                            // Preserve user-toggled direction; clock sync may have overwritten isReversed.
                            self.isReversed = wantReversed
                            self.scheduleLoopingRegion(region, resumeAt: resumeAt)
                            return
                        }
                        self.updateCurrentTimeFromClock()
                        self.stopPosition = self.currentTime
                        self.updateMeter(at: self.currentTime)
                        return
                    }

                    // Looping was turned off mid-playback — continue linearly from here.
                    self.updateCurrentTimeFromClock()
                    let resumeAt = self.currentTime
                    self.invalidateScheduledSegment()
                    self.scheduleAndPlay(from: resumeAt)
                    return
                }

                self.updateCurrentTimeFromClock()
                let time = self.currentTime

                // Backup in case the node completion callback is late.
                if self.scheduledIsReversed {
                    if time <= self.scheduledSegmentEnd + 0.001 {
                        self.handleReachedSegmentEnd(from: time)
                        return
                    }
                } else if time >= self.scheduledSegmentEnd - 0.001 {
                    self.handleReachedSegmentEnd(from: time)
                    return
                }

                // Direction flipped mid one-shot playback.
                if self.isReversed != self.scheduledIsReversed {
                    self.invalidateScheduledSegment()
                    self.scheduleAndPlay(from: time)
                    return
                }

                self.stopPosition = time
                self.updateMeter(at: time)
            }
        }
    }

    private func updateMeter(at time: Double) {
        guard isPlaying, let meterFile else {
            decayMeter()
            return
        }

        let sampleRate = meterFile.processingFormat.sampleRate
        let windowFrames = AVAudioFrameCount(min(4096, max(256, Int(sampleRate * 0.05))))
        let startFrame = AVAudioFramePosition(time * sampleRate)
        guard startFrame < meterFile.length else {
            decayMeter()
            return
        }

        let frameCount = min(windowFrames, AVAudioFrameCount(meterFile.length - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: meterFile.processingFormat, frameCapacity: frameCount) else {
            return
        }

        meterFile.framePosition = startFrame
        do {
            try meterFile.read(into: buffer, frameCount: frameCount)
        } catch {
            decayMeter()
            return
        }

        let measured = measure(buffer: buffer)
        applyChannelBallistics(
            leftPeak: measured.leftPeak * volume,
            leftRMS: measured.leftRMS * volume,
            rightPeak: measured.rightPeak * volume,
            rightRMS: measured.rightRMS * volume
        )
    }

    private func applyChannelBallistics(
        leftPeak: Float,
        leftRMS: Float,
        rightPeak: Float,
        rightRMS: Float
    ) {
        meterLeftPeakLinear = leftPeak > meterLeftPeakLinear ? leftPeak : meterLeftPeakLinear * 0.82
        meterRightPeakLinear = rightPeak > meterRightPeakLinear ? rightPeak : meterRightPeakLinear * 0.82
        meterLeftRMSLinear = integrateVU(current: meterLeftRMSLinear, target: leftRMS)
        meterRightRMSLinear = integrateVU(current: meterRightRMSLinear, target: rightRMS)
        meterLevels.left.peakDB = linearToDB(meterLeftPeakLinear)
        meterLevels.left.rmsDB = linearToDB(meterLeftRMSLinear)
        meterLevels.right.peakDB = linearToDB(meterRightPeakLinear)
        meterLevels.right.rmsDB = linearToDB(meterRightRMSLinear)
    }

    private func integrateVU(current: Float, target: Float) -> Float {
        if target > current {
            return current * 0.72 + target * 0.28
        }
        return current * 0.90 + target * 0.10
    }

    private func decayMeter() {
        meterLeftPeakLinear *= 0.75
        meterRightPeakLinear *= 0.75
        meterLeftRMSLinear *= 0.82
        meterRightRMSLinear *= 0.82
        if meterLeftPeakLinear < 0.000_05 && meterRightPeakLinear < 0.000_05 {
            resetMeter()
        } else {
            meterLevels.left.peakDB = linearToDB(meterLeftPeakLinear)
            meterLevels.left.rmsDB = linearToDB(meterLeftRMSLinear)
            meterLevels.right.peakDB = linearToDB(meterRightPeakLinear)
            meterLevels.right.rmsDB = linearToDB(meterRightRMSLinear)
        }
    }

    private func resetMeter() {
        meterLeftPeakLinear = 0
        meterLeftRMSLinear = 0
        meterRightPeakLinear = 0
        meterRightRMSLinear = 0
        meterLevels = PlaybackMeterLevels()
    }

    private func measure(buffer: AVAudioPCMBuffer) -> (leftPeak: Float, leftRMS: Float, rightPeak: Float, rightRMS: Float) {
        guard let channels = buffer.floatChannelData else { return (0, 0, 0, 0) }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0 else { return (0, 0, 0, 0) }

        func channelStats(_ ch: Int) -> (peak: Float, rms: Float) {
            var peak: Float = 0
            var sumSquares: Float = 0
            for i in 0..<frames {
                let sample = abs(channels[ch][i])
                peak = max(peak, sample)
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Float(max(1, frames)))
            return (peak, rms)
        }

        let left = channelStats(0)
        let right = channelCount > 1 ? channelStats(1) : left
        return (left.peak, left.rms, right.peak, right.rms)
    }

    private func linearToDB(_ value: Float) -> Float {
        guard value > 0.000_000_5 else { return -80 }
        return max(-80, 20 * log10(value))
    }

    private func finishSelectionPlayback(at end: Double) {
        invalidateScheduledSegment()
        playerNode.stop()
        isPlaying = false
        isPaused = false
        playbackClockStart = nil
        stopTimer()
        stopPosition = end
        currentTime = end
        decayMeter()
    }

    private func finishFilePlayback() {
        invalidateScheduledSegment()
        playerNode.stop()
        isPlaying = false
        isPaused = false
        playbackClockStart = nil
        stopTimer()
        stopPosition = 0
        currentTime = 0
        resetMeter()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// True when the live loop region differs from the region currently scheduled as a loop buffer.
    private func loopRegionChanged(_ region: ClosedRange<Double>) -> Bool {
        guard let active = loopBufferRegion else { return true }
        let end = min(duration, region.upperBound)
        return abs(active.lowerBound - region.lowerBound) > 0.0005
            || abs(active.upperBound - end) > 0.0005
    }

    private static func validRegion(_ region: ClosedRange<Double>?) -> ClosedRange<Double>? {
        guard let region, region.upperBound - region.lowerBound > 0.001 else { return nil }
        return region
    }

    private static func clampedRate(_ rate: Float) -> Float {
        max(0.25, min(4.0, rate))
    }

    private static func pitchRatioToCents(_ ratio: Float) -> Float {
        let clamped = max(0.25, min(4.0, ratio))
        return Float(1200.0 * log2(Double(clamped)))
    }
}
