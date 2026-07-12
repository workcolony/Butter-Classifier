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

    /// One-shot playback of the waveform selection when repeat is off.
    private var oneShotRegion: ClosedRange<Double>? {
        guard !isLooping else { return nil }
        return playbackRegion
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

    /// Start time when pressing play — loops always start at the loop's beginning;
    /// one-shot selections snap into range when the cursor is outside it.
    private func playbackStartTime(_ time: Double) -> Double {
        if let region = loopingRegion {
            return region.lowerBound
        }
        let t = clamp(time)
        if let region = oneShotRegion {
            if t < region.lowerBound || t >= region.upperBound {
                return region.lowerBound
            }
        }
        return t
    }

    /// End time for the next scheduled segment starting at `start`.
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

    private func scheduleAndPlay(from startTime: Double) {
        guard let audioFile else { return }

        // Gapless looping: pre-read the loop region and let the node loop it internally.
        if let region = loopingRegion {
            scheduleLoopingRegion(region)
            return
        }

        // Whole-file repeat from the start — same gapless buffer path as loop braces.
        if let region = wholeFileLoopRegion, clamp(startTime) <= 0.0005 {
            scheduleLoopingRegion(region)
            return
        }

        isLoopBufferPlaying = false
        loopBufferRegion = nil

        let start = clamp(startTime)
        let end = segmentEndTime(from: start)

        if start >= end - 0.0005 {
            handleReachedSegmentEnd(from: start)
            return
        }

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

        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
        isPlaying = true
        isPaused = false
        playbackFileOrigin = start
        playbackClockStart = CFAbsoluteTimeGetCurrent()
        currentTime = start
        stopPosition = start
        startTimer()
    }

    private func handleSegmentCompleted(segmentID: Int) {
        guard isPlaying, segmentID == scheduledSegmentID else { return }
        handleReachedSegmentEnd(from: scheduledSegmentEnd)
    }

    private func handleReachedSegmentEnd(from time: Double) {
        guard isPlaying else { return }
        invalidateScheduledSegment()

        if let region = loopingRegion {
            scheduleAndPlay(from: region.lowerBound)
            return
        }
        if let region = oneShotRegion {
            finishSelectionPlayback(at: min(region.upperBound, duration))
            return
        }
        if let region = wholeFileLoopRegion {
            scheduleLoopingRegion(region)
            return
        }
        finishFilePlayback()
    }

    /// Schedules the loop region as a single buffer that the node repeats internally,
    /// giving sample-accurate, gapless looping (no delay between end and start).
    private func scheduleLoopingRegion(_ region: ClosedRange<Double>) {
        guard let audioFile else { return }

        let start = clamp(region.lowerBound)
        let end = min(duration, region.upperBound)
        let startFrame = AVAudioFramePosition(start * sampleRate)
        let endFrame = AVAudioFramePosition(end * sampleRate)
        guard endFrame > startFrame, startFrame < audioFile.length else {
            finishFilePlayback()
            return
        }

        let frameCount = AVAudioFrameCount(min(endFrame - startFrame, audioFile.length - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            finishFilePlayback()
            return
        }

        do {
            audioFile.framePosition = startFrame
            try audioFile.read(into: buffer, frameCount: frameCount)
        } catch {
            finishFilePlayback()
            return
        }

        scheduledSegmentID += 1
        scheduledSegmentEnd = end
        isLoopBufferPlaying = true
        loopBufferRegion = start...end

        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionCallbackType: .dataPlayedBack) { _ in }

        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
        isPlaying = true
        isPaused = false
        playbackFileOrigin = start
        playbackClockStart = CFAbsoluteTimeGetCurrent()
        currentTime = start
        stopPosition = start
        startTimer()
    }

    private func invalidateScheduledSegment() {
        scheduledSegmentID += 1
        isLoopBufferPlaying = false
        loopBufferRegion = nil
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
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let filePos = playbackFileOrigin + elapsed * Double(Self.clampedRate(playbackRate))
        if isLoopBufferPlaying, let region = loopBufferRegion {
            let loopLen = region.upperBound - region.lowerBound
            if loopLen > 0 {
                var rel = (filePos - region.lowerBound).truncatingRemainder(dividingBy: loopLen)
                if rel < 0 { rel += loopLen }
                currentTime = region.lowerBound + rel
                return
            }
        }
        currentTime = min(duration, filePos)
    }

    private func clamp(_ time: Double) -> Double {
        max(0, min(time, duration > 0 ? duration : 0))
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }

                // Gapless loop buffer: the node repeats internally — only follow region edits.
                if self.isLoopBufferPlaying {
                    if self.isLooping {
                        let region = self.loopingRegion ?? self.wholeFileLoopRegion
                        if let region, self.loopRegionChanged(region) {
                            self.invalidateScheduledSegment()
                            self.scheduleLoopingRegion(region)
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
                if time >= self.scheduledSegmentEnd - 0.001 {
                    self.handleReachedSegmentEnd(from: time)
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
