import Accelerate
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import SRCore

/// In-memory byte source for `AudioFileOpenWithCallbacks` so MP3/WAV decoding
/// never touches disk (no temp files in /tmp, even in no-cache mode).
private final class MemoryAudioBox {
    let data: Data
    init(_ data: Data) { self.data = data }
}

private func memoryAudioReadProc(
    _ clientData: UnsafeMutableRawPointer,
    _ inPosition: Int64,
    _ requestCount: UInt32,
    _ buffer: UnsafeMutableRawPointer,
    _ actualCount: UnsafeMutablePointer<UInt32>
) -> OSStatus {
    let box = Unmanaged<MemoryAudioBox>.fromOpaque(clientData).takeUnretainedValue()
    let total = Int64(box.data.count)
    if inPosition < 0 || inPosition >= total {
        actualCount.pointee = 0
        return noErr
    }
    let available = Int(min(Int64(requestCount), total - inPosition))
    if available > 0 {
        let start = Int(inPosition)
        box.data.copyBytes(
            to: buffer.assumingMemoryBound(to: UInt8.self),
            from: start..<(start + available))
    }
    actualCount.pointee = UInt32(available)
    return noErr
}

private func memoryAudioGetSizeProc(_ clientData: UnsafeMutableRawPointer) -> Int64 {
    let box = Unmanaged<MemoryAudioBox>.fromOpaque(clientData).takeUnretainedValue()
    return Int64(box.data.count)
}

/// Maps each scheduled player buffer's rendered sample span back to its exact
/// content frame span, eliminating cumulative WSOLA length drift across long
/// reads at any playback rate.
struct ScheduledSpan {
    let contentStart: AVAudioFramePosition
    let contentLength: AVAudioFramePosition
    let renderedStart: AVAudioFramePosition
    let renderedLength: AVAudioFramePosition

    func contentFrame(forRenderedSample sample: AVAudioFramePosition) -> AVAudioFramePosition {
        guard renderedLength > 0 else { return contentStart }
        let clampedOffset = min(max(sample - renderedStart, 0), renderedLength)
        let fraction = Double(clampedOffset) / Double(renderedLength)
        return contentStart + AVAudioFramePosition((fraction * Double(contentLength)).rounded())
    }
}

/// Ordered cursor for a bounded seek/rate-change rerender. Keeping the cursor
/// active at the current tail lets segments decoded mid-rerender join the same
/// ordered stream instead of being scheduled early and then repeated.
struct RerenderWindowCursor {
    private(set) var nextSegmentIndex: Int?
    private var firstOffset: AVAudioFrameCount = 0

    var isActive: Bool { nextSegmentIndex != nil }

    mutating func begin(at index: Int, firstOffset: AVAudioFrameCount) {
        nextSegmentIndex = index
        self.firstOffset = firstOffset
    }

    mutating func takeNext(existingSegmentCount: Int)
        -> (index: Int, offset: AVAudioFrameCount)? {
        guard let index = nextSegmentIndex, index < existingSegmentCount else { return nil }
        let offset = firstOffset
        firstOffset = 0
        // Deliberately retain `existingSegmentCount` as the next index at the
        // current tail; a later decode can then be consumed in order.
        nextSegmentIndex = index + 1
        return (index, offset)
    }

    mutating func reset() {
        nextSegmentIndex = nil
        firstOffset = 0
    }
}

/// Timeline audio player with time-domain speed control, in-memory decoding,
/// frame-accurate progress tracking, and seeking (F-7, F-8).
///
/// Speed is applied by stretching PCM with WSOLA (see TimeStretch) at
/// schedule time, not by a realtime phase-vocoder node — phase vocoders
/// (AVAudioUnitTimePitch) smear speech transients into a reverberant
/// "bright room" artifact at higher rates. The graph is therefore just
/// player → mixer in one canonical format (44.1 kHz mono float).
///
/// The content timeline (original 1.0× audio, inter-sentence silence baked
/// in) is kept verbatim as compressed bytes; what's scheduled on the player
/// is the stretched rendering at the current rate. Rate changes and seeks
/// re-render from the current content position — segment by segment, off the
/// main thread, with 5 ms raised-cosine de-click ramps.
///
/// Positions are mapped through exact per-buffer `ScheduledSpan` intervals,
/// so sentence progress, seeks, and pauses stay frame-accurate across
/// hundreds of sentences at any speed with zero cumulative WSOLA drift.
@MainActor
final class PlaybackEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case playing
        case paused
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentSentence = 0
    @Published private(set) var totalSentences = 0
    @Published private(set) var currentSeconds: Double = 0
    @Published private(set) var availableSeconds: Double = 0
    @Published private(set) var decodedSentences = 0
    @Published private(set) var isBuffering = false

    var rate: Double {
        didSet {
            guard abs(rate - oldValue) > 0.001 else { return }
            scheduleRateChange(immediate: false)
        }
    }
    var sentencePauseMS: Int
    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?

    nonisolated static let sampleRate: Double = 44_100
    /// Conservative edge-silence cap on decoded cloud/local audio so trailing
    /// encoder dead air doesn't stack on top of `sentencePauseMS`.
    private nonisolated static let maxLeadingSilenceSeconds: Double = 0.035
    private nonisolated static let maxTrailingSilenceSeconds: Double = 0.060
    private nonisolated static let microFadeFrames: Int = 220  // ~5 ms @ 44.1 kHz

    private let format = AVAudioFormat(
        standardFormatWithSampleRate: PlaybackEngine.sampleRate, channels: 1)!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private struct Segment {
        let encodedAudio: Data
        let pauseFrames: AVAudioFrameCount
        let frameLength: AVAudioFramePosition
    }

    // Content timeline metadata + compressed source audio. PCM is decoded on
    // a worker for initial playback and on demand for seek/rate changes, so a
    // long read does not retain its entire uncompressed waveform in memory.
    private var segments: [Segment] = []
    private var segmentStartFrames: [AVAudioFramePosition] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var pendingFeeds: [Int: Data] = [:]
    private var receivedCount = 0
    private var appendedCount = 0
    private var pendingDecodes = 0
    private var pendingRenders = 0
    private var rerenderCursor = RerenderWindowCursor()
    private let renderWindowSize = 4

    // Playback run state.
    private var renderRate: Double = 1.0                // rate of scheduled audio
    private var pausedAtFrame: AVAudioFramePosition = 0
    private var scheduledSpans: [ScheduledSpan] = []
    private var renderedFramesScheduled: AVAudioFramePosition = 0
    private var outstandingBuffers = 0
    private var generation = 0
    private var sessionGeneration = 0
    private var uiTimer: Timer?
    private var engineStarted = false
    private var rateChangeWork: DispatchWorkItem?
    private var configChangeWork: DispatchWorkItem?
    private var engineRetryWork: DispatchWorkItem?
    private var starvationPaused = false {
        didSet { updateBufferingState() }
    }

    /// Serial chains so decode and stretch+schedule ops run in timeline order
    /// off the main thread. Tracked in arrays so `stop()` / `rescheduleContent()`
    /// actually cancel queued tasks instead of leaving them running.
    private var chain: Task<Void, Never> = Task {}
    private var renderTasks: [Task<Void, Never>] = []
    private var decodeChain: Task<Void, Never> = Task {}
    private var decodeTasks: [Task<Void, Never>] = []

    /// Only written in `init` and removed in `deinit` once no references remain.
    nonisolated(unsafe) private var configObserver: NSObjectProtocol?

    init(rate: Double = 1.0, sentencePauseMS: Int = 400) {
        self.rate = rate
        self.sentencePauseMS = sentencePauseMS
        renderRate = rate

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Output configuration changes (AirPods profile/sample-rate switch,
        // device change) stop the engine and drop scheduled audio. Debounce
        // rapid notifications during Bluetooth handoff, then re-render from
        // the last known content frame.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleConfigurationRecovery()
            }
        }
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func scheduleConfigurationRecovery() {
        guard isActive else { return }
        configChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isActive else { return }
                SRLog.event("playback.config_change", [:])
                self.engineStarted = self.engine.isRunning
                self.rescheduleContent(from: self.pausedAtFrame)
            }
        }
        configChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    var isActive: Bool { state != .idle }

    /// Update speed without the slider drag debounce (used by one-click preset chips).
    func setRate(_ newRate: Double, immediate: Bool) {
        let clamped = min(max(newRate, 0.5), 3.0)
        guard abs(clamped - rate) > 0.001 else { return }
        rate = clamped
        if immediate {
            scheduleRateChange(immediate: true)
        }
    }

    // MARK: - Session

    func startSession(totalSentences total: Int) {
        stop()
        generation += 1
        totalSentences = total
        renderRate = rate
        state = .playing
        updateBufferingState()
        startUITimer()
    }

    /// Deliver audio for sentence `index` (may arrive out of order; the
    /// timeline appends strictly in order).
    func feed(index: Int, audio: Data) {
        guard isActive else { return }
        pendingFeeds[index] = audio
        while let data = pendingFeeds[receivedCount] {
            let index = receivedCount
            pendingFeeds[index] = nil
            receivedCount += 1
            enqueueDecode(sentence: index, data: data)
        }
    }

    private func enqueueDecode(sentence index: Int, data: Data) {
        let pauseFrames = index == 0 ? 0 : AVAudioFrameCount(
            Double(sentencePauseMS) / 1000.0 * Self.sampleRate)
        let sessionGen = sessionGeneration
        let previous = decodeChain
        pendingDecodes += 1
        let task = Task { [weak self] in
            await previous.value
            guard let self, !Task.isCancelled else { return }
            guard await MainActor.run(body: { self.sessionGeneration == sessionGen }) else { return }
            let worker = Task.detached(priority: .userInitiated) {
                Self.decodeBlock(data, pauseFrames: pauseFrames)
            }
            let block = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.finishDecode(
                    sentence: index,
                    data: data,
                    pauseFrames: pauseFrames,
                    block: block,
                    sessionGeneration: sessionGen)
            }
        }
        decodeChain = task
        decodeTasks.append(task)
    }

    private func finishDecode(
        sentence index: Int,
        data: Data,
        pauseFrames: AVAudioFrameCount,
        block: AVAudioPCMBuffer?,
        sessionGeneration sessionGen: Int
    ) {
        guard sessionGen == sessionGeneration, isActive else { return }
        pendingDecodes = max(pendingDecodes - 1, 0)
        guard let block else {
            SRLog.error("playback.decode_failed", ["index": String(index)])
            failPlayback("Audio for sentence \(index + 1) could not be decoded.")
            return
        }

        let startFrame = totalFrames
        let length = AVAudioFramePosition(block.frameLength)
        segmentStartFrames.append(startFrame)
        segments.append(Segment(
            encodedAudio: data,
            pauseFrames: pauseFrames,
            frameLength: length))
        totalFrames += length
        availableSeconds = Double(totalFrames) / Self.sampleRate
        appendedCount += 1
        decodedSentences = appendedCount

        if rerenderCursor.isActive {
            // A seek/rate rerender owns scheduling order until the session
            // ends. Its cursor will consume this newly appended segment.
            pumpRerenderWindow()
        } else {
            enqueueStretchAndSchedule(
                block,
                contentStart: startFrame,
                contentLength: length,
                isFinal: index == totalSentences - 1)
        }
    }

    // MARK: - Transport (F-7)

    func pause() {
        guard state == .playing else { return }
        pausedAtFrame = currentFrame
        player.pause()
        starvationPaused = false
        state = .paused
        updateBufferingState()
        SRLog.event("playback.pause", [:])
    }

    func resume() {
        guard state == .paused else { return }
        state = .playing
        guard ensureEngineRunning(allowRetry: true) else { return }
        if outstandingBuffers > 0 {
            player.play()
            starvationPaused = false
        } else {
            // Stay clock-paused until the next decoded/rendered buffer lands.
            starvationPaused = true
        }
        updateBufferingState()
        SRLog.event("playback.resume", [:])
        // The last buffer's completion may have fired while paused (its
        // checkFinished no-ops on state != .playing) — re-check, or a
        // finished timeline resumes into eternal silence.
        checkFinished()
    }

    func togglePauseResume() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .idle: break
        }
    }

    private func cancelRenderTasks() {
        for task in renderTasks { task.cancel() }
        renderTasks.removeAll()
        chain = Task {}
    }

    private func cancelDecodeTasks() {
        for task in decodeTasks { task.cancel() }
        decodeTasks.removeAll()
        decodeChain = Task {}
    }

    func stop() {
        generation += 1
        sessionGeneration += 1
        cancelRenderTasks()
        cancelDecodeTasks()
        rateChangeWork?.cancel()
        rateChangeWork = nil
        configChangeWork?.cancel()
        configChangeWork = nil
        engineRetryWork?.cancel()
        engineRetryWork = nil
        uiTimer?.invalidate()
        uiTimer = nil
        if engineStarted || engine.isRunning {
            player.stop()
            // Release the output audio unit / device claim: a menu-bar app
            // idles most of the time and shouldn't stay an active audio
            // client (power drain; can pin AirPods in the call profile).
            engine.stop()
            engineStarted = false
        }
        segments.removeAll()
        segmentStartFrames.removeAll()
        pendingFeeds.removeAll()
        scheduledSpans.removeAll()
        renderedFramesScheduled = 0
        totalFrames = 0
        receivedCount = 0
        appendedCount = 0
        decodedSentences = 0
        pendingDecodes = 0
        pendingRenders = 0
        rerenderCursor.reset()
        pausedAtFrame = 0
        outstandingBuffers = 0
        starvationPaused = false
        isBuffering = false
        currentSentence = 0
        totalSentences = 0
        currentSeconds = 0
        availableSeconds = 0
        state = .idle
    }

    /// Seek by ±seconds of content time, clamped to decoded audio.
    func seek(by deltaSeconds: Double) {
        guard isActive else { return }
        let delta = AVAudioFramePosition(deltaSeconds * Self.sampleRate)
        rescheduleContent(from: currentFrame + delta)
        SRLog.event("playback.seek", ["delta_s": String(Int(deltaSeconds))])
    }

    /// Seek directly to an absolute content timestamp within decoded audio.
    func seek(toSeconds targetSeconds: Double) {
        guard isActive, totalFrames > 0 else { return }
        let target = AVAudioFramePosition((targetSeconds * Self.sampleRate).rounded())
        rescheduleContent(from: target)
    }

    /// Jump forward or backward by whole sentences within decoded audio.
    func skipSentence(by delta: Int) {
        guard isActive, !segmentStartFrames.isEmpty else { return }
        let targetIndex = min(max(0, currentSentence + delta), segmentStartFrames.count - 1)
        rescheduleContent(from: segmentStartFrames[targetIndex])
    }

    /// Restart from the top.
    func restart() {
        guard isActive else { return }
        rescheduleContent(from: 0)
    }

    // MARK: - Rendering

    /// Debounced for slider drags; immediate for one-click speed presets.
    private func scheduleRateChange(immediate: Bool) {
        guard isActive else {
            renderRate = rate
            return
        }
        rateChangeWork?.cancel()
        rateChangeWork = nil
        if immediate {
            rescheduleContent(from: currentFrame)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isActive else { return }
                self.rescheduleContent(from: self.currentFrame)
            }
        }
        rateChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Stop the player and re-render + re-schedule everything from `target`
    /// (content frames) at the current rate. Used by seek, restart, and
    /// rate changes; also safe while paused (stays paused at the new spot).
    private func rescheduleContent(from target: AVAudioFramePosition) {
        guard totalFrames > 0 else {
            // No audio yet, but the requested rate must still take effect —
            // otherwise every segment appended before the first decode plays
            // at the session-start rate until the next seek/rate change.
            renderRate = rate
            return
        }
        let clamped = min(max(0, target), totalFrames - 1)

        generation += 1          // invalidate stale completions and chain ops
        cancelRenderTasks()
        engineRetryWork?.cancel()
        engineRetryWork = nil
        pendingRenders = 0
        player.stop()            // clears queue; playerTime resets
        scheduledSpans.removeAll()
        renderedFramesScheduled = 0
        outstandingBuffers = 0
        starvationPaused = state == .playing
        renderRate = rate
        pausedAtFrame = clamped

        guard let startSegment = segmentIndex(containing: clamped) else { return }
        rerenderCursor.begin(
            at: startSegment,
            firstOffset: AVAudioFrameCount(clamped - segmentStartFrames[startSegment]))
        pumpRerenderWindow()
        updateUIPosition()
    }

    /// Keep only a small decoded/rendered window ahead of the playhead. A
    /// seek or rate change on a long read must not decode every remaining
    /// compressed segment at once.
    private func pumpRerenderWindow() {
        while pendingRenders + outstandingBuffers < renderWindowSize,
              let next = rerenderCursor.takeNext(existingSegmentCount: segments.count) {
            let segment = segments[next.index]
            let contentStart = segmentStartFrames[next.index] + AVAudioFramePosition(next.offset)
            let contentLength = max(segment.frameLength - AVAudioFramePosition(next.offset), 1)
            enqueueSegmentRender(
                segment,
                offset: next.offset,
                contentStart: contentStart,
                contentLength: contentLength,
                isFinal: next.index == totalSentences - 1)
        }
    }

    /// Re-decode a compressed segment for seek/rate-change rendering. This is
    /// intentionally in the serial render chain so timeline order is stable.
    private func enqueueSegmentRender(
        _ segment: Segment,
        offset: AVAudioFrameCount,
        contentStart: AVAudioFramePosition,
        contentLength: AVAudioFramePosition,
        isFinal: Bool
    ) {
        let gen = generation
        let rate = renderRate
        let previous = chain
        pendingRenders += 1
        let task = Task { [weak self] in
            await previous.value
            guard let self, !Task.isCancelled else { return }
            guard await MainActor.run(body: { self.generation == gen }) else { return }
            let worker = Task.detached(priority: .userInitiated) {
                () -> AVAudioPCMBuffer? in
                guard !Task.isCancelled else { return nil }
                guard let block = Self.decodeBlock(
                    segment.encodedAudio, pauseFrames: segment.pauseFrames),
                      let partial = Self.slice(block, from: offset) else { return nil }
                guard !Task.isCancelled else { return nil }
                return TimeStretch.stretch(partial, rate: rate)
            }
            let rendered = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.finishRender(
                    rendered,
                    contentStart: contentStart,
                    contentLength: contentLength,
                    generation: gen,
                    isFinal: isFinal)
            }
        }
        chain = task
        renderTasks.append(task)
    }

    /// Append a stretch+schedule op to the serial chain. Stretching runs
    /// off the main actor; scheduling hops back and is generation-guarded.
    private func enqueueStretchAndSchedule(
        _ buffer: AVAudioPCMBuffer,
        contentStart: AVAudioFramePosition,
        contentLength: AVAudioFramePosition,
        isFinal: Bool
    ) {
        let gen = generation
        let rate = renderRate
        let previous = chain
        pendingRenders += 1
        let task = Task { [weak self] in
            await previous.value
            guard let self, !Task.isCancelled else { return }
            // Bail before stretching, not just before scheduling: stop() and
            // reschedules cancel this chain so WSOLA never wastes CPU on stale audio.
            guard await MainActor.run(body: { self.generation == gen }) else { return }
            let worker = Task.detached(priority: .userInitiated) {
                TimeStretch.stretch(buffer, rate: rate)
            }
            let stretched = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.finishRender(
                    stretched,
                    contentStart: contentStart,
                    contentLength: contentLength,
                    generation: gen,
                    isFinal: isFinal)
            }
        }
        chain = task
        renderTasks.append(task)
    }

    private func finishRender(
        _ buffer: AVAudioPCMBuffer?,
        contentStart: AVAudioFramePosition,
        contentLength: AVAudioFramePosition,
        generation gen: Int,
        isFinal: Bool
    ) {
        guard gen == generation, isActive else { return }
        pendingRenders = max(pendingRenders - 1, 0)
        guard let buffer else {
            failPlayback("Audio could not be decoded while seeking.")
            return
        }
        scheduleStretched(
            buffer,
            contentStart: contentStart,
            contentLength: contentLength,
            generation: gen,
            isFinal: isFinal)
    }

    private func scheduleStretched(
        _ buffer: AVAudioPCMBuffer,
        contentStart: AVAudioFramePosition,
        contentLength: AVAudioFramePosition,
        generation gen: Int,
        isFinal: Bool
    ) {
        guard gen == generation, isActive else { return }
        // Only claim and start the audio device while actually playing —
        // seeking, rate changes, or late decodes while paused must not wake
        // the audio hardware until the user presses Resume.
        if state == .playing {
            guard ensureEngineRunning(allowRetry: true) else { return }
        }
        let span = ScheduledSpan(
            contentStart: contentStart,
            contentLength: contentLength,
            renderedStart: renderedFramesScheduled,
            renderedLength: AVAudioFramePosition(buffer.frameLength))
        scheduledSpans.append(span)
        renderedFramesScheduled += span.renderedLength
        outstandingBuffers += 1
        // Refill/freeze the content clock as soon as non-final audio renders.
        // Only the final buffer waits for device latency; its completion may
        // stop the engine, so an earlier callback would truncate the tail.
        let completionType: AVAudioPlayerNodeCompletionCallbackType = isFinal ? .dataPlayedBack : .dataRendered
        player.scheduleBuffer(buffer, completionCallbackType: completionType) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.outstandingBuffers -= 1
                self.pumpRerenderWindow()
                if self.outstandingBuffers == 0,
                   !PlaybackCompletionPolicy.canFinish(
                    totalSentences: self.totalSentences,
                    appendedSentences: self.appendedCount,
                    pendingDecodes: self.pendingDecodes,
                    pendingRenders: self.pendingRenders,
                    scheduledBuffers: self.outstandingBuffers) {
                    self.pausedAtFrame = self.currentFrame
                    self.player.pause()
                    self.starvationPaused = true
                }
                self.checkFinished()
            }
        }
        if state == .playing, !player.isPlaying {
            player.play()
            starvationPaused = false
        }
        updateBufferingState()
    }

    // MARK: - Position

    private var currentFrame: AVAudioFramePosition {
        guard state == .playing,
              !starvationPaused,
              player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              !scheduledSpans.isEmpty else {
            return pausedAtFrame
        }
        return Self.contentFrame(forRenderedSample: playerTime.sampleTime, in: scheduledSpans, totalFrames: totalFrames)
    }

    nonisolated static func contentFrame(
        forRenderedSample sampleTime: AVAudioFramePosition,
        in spans: [ScheduledSpan],
        totalFrames: AVAudioFramePosition
    ) -> AVAudioFramePosition {
        guard !spans.isEmpty else { return 0 }
        let sample = max(sampleTime, 0)
        // Binary search for the last span with renderedStart <= sample.
        var low = 0
        var high = spans.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if spans[mid].renderedStart <= sample { low = mid } else { high = mid - 1 }
        }
        let mapped = spans[low].contentFrame(forRenderedSample: sample)
        return min(max(mapped, 0), totalFrames)
    }

    private func segmentIndex(containing frame: AVAudioFramePosition) -> Int? {
        guard !segmentStartFrames.isEmpty else { return nil }
        var low = 0
        var high = segmentStartFrames.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segmentStartFrames[mid] <= frame { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func updateBufferingState() {
        isBuffering = state == .playing && (totalFrames == 0 || starvationPaused)
    }

    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateUIPosition()
            }
        }
    }

    private func updateUIPosition() {
        let frame = currentFrame
        currentSeconds = Double(frame) / Self.sampleRate
        if let index = segmentIndex(containing: frame) {
            currentSentence = index
        }
        // Keep the fallback position fresh: it's the resume point after an
        // engine configuration change, when playerTime is unavailable.
        if state == .playing, !starvationPaused {
            pausedAtFrame = frame
        }
        updateBufferingState()
    }

    private func checkFinished() {
        guard state == .playing,
              PlaybackCompletionPolicy.canFinish(
                totalSentences: totalSentences,
                appendedSentences: appendedCount,
                pendingDecodes: pendingDecodes,
                pendingRenders: pendingRenders,
                scheduledBuffers: outstandingBuffers) else { return }
        let n = totalSentences
        stop()
        SRLog.event("playback.finished", ["sentences": String(n)])
        onFinished?()
    }

    // MARK: - Engine / decode

    @discardableResult
    private func ensureEngineRunning(allowRetry: Bool) -> Bool {
        guard !engine.isRunning else {
            engineStarted = true
            return true
        }
        do {
            try engine.start()
            engineStarted = true
            return true
        } catch {
            if allowRetry {
                // Bluetooth/AirPods handoffs can momentarily reject engine.start()
                // for ~100–250 ms. Retry once before failing the session.
                SRLog.event("playback.engine_start_retry", [:])
                let gen = generation
                engineRetryWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        guard self.isActive, self.generation == gen, self.state == .playing else { return }
                        if self.ensureEngineRunning(allowRetry: false), self.outstandingBuffers > 0 {
                            self.player.play()
                            self.starvationPaused = false
                        }
                    }
                }
                engineRetryWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
                return false
            }
            SRLog.error("playback.engine_start", ["error": String(describing: error)])
            failPlayback("The audio output device could not be started.")
            return false
        }
    }

    private func failPlayback(_ message: String) {
        let callback = onError
        stop()
        callback?(message)
    }

    /// Decode MP3/WAV Data completely in memory (zero temp files on disk) →
    /// canonical 44.1 kHz mono Float32 buffer, with conservative edge-silence
    /// capping so cloud/local silence pads don't stack on `sentencePauseMS`.
    nonisolated static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        guard !data.isEmpty else { return nil }

        let hint: AudioFileTypeID
        if AudioPayloadValidator.isWAV(data) {
            hint = kAudioFileWAVEType
        } else if AudioPayloadValidator.isMP3(data) {
            hint = kAudioFileMP3Type
        } else {
            hint = 0
        }

        let box = MemoryAudioBox(data)
        let unmanaged = Unmanaged.passUnretained(box)
        var audioFileID: AudioFileID?
        let openStatus = AudioFileOpenWithCallbacks(
            unmanaged.toOpaque(),
            memoryAudioReadProc,
            nil,
            memoryAudioGetSizeProc,
            nil,
            hint,
            &audioFileID
        )
        guard openStatus == noErr, let audioFile = audioFileID else {
            SRLog.error("playback.decode", ["stage": "open", "status": String(openStatus)])
            return nil
        }
        defer { AudioFileClose(audioFile) }

        var extFileID: ExtAudioFileRef?
        let wrapStatus = ExtAudioFileWrapAudioFileID(audioFile, false, &extFileID)
        guard wrapStatus == noErr, let extFile = extFileID else {
            SRLog.error("playback.decode", ["stage": "wrap", "status": String(wrapStatus)])
            return nil
        }
        defer { ExtAudioFileDispose(extFile) }

        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let propStatus = ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard propStatus == noErr else {
            SRLog.error("playback.decode", ["stage": "format", "status": String(propStatus)])
            return nil
        }

        let chunkFrames: UInt32 = 16_384
        var scratch = [Float](repeating: 0, count: Int(chunkFrames))
        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleRate * 4))

        while true {
            var frameCount = chunkFrames
            let readStatus: OSStatus = scratch.withUnsafeMutableBytes { raw in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(raw.count),
                        mData: raw.baseAddress
                    )
                )
                return ExtAudioFileRead(extFile, &frameCount, &bufferList)
            }
            guard readStatus == noErr else {
                SRLog.error("playback.decode", ["stage": "read", "status": String(readStatus)])
                return nil
            }
            if frameCount == 0 { break }
            samples.append(contentsOf: scratch[0..<Int(frameCount)])
        }

        guard !samples.isEmpty else { return nil }
        let trimmed = trimExcessiveEdgeSilence(samples)
        guard let target = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(trimmed.count)),
              let outPtr = out.floatChannelData?[0] else {
            return nil
        }
        trimmed.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            outPtr.update(from: base, count: trimmed.count)
        }
        out.frameLength = AVAudioFrameCount(trimmed.count)
        return out
    }

    /// Conservatively cap excessive leading/trailing dead air while preserving
    /// natural breaths/pads and applying a 5 ms micro-fade at any trimmed edge.
    /// All-silent buffers pass through untouched.
    nonisolated static func trimExcessiveEdgeSilence(_ samples: [Float]) -> [Float] {
        let count = samples.count
        guard count > 0 else { return samples }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        let threshold = max(peak * 0.004, 1e-4)
        guard peak > threshold else { return samples }

        var firstVoiced = 0
        while firstVoiced < count && abs(samples[firstVoiced]) <= threshold {
            firstVoiced += 1
        }
        var lastVoiced = count - 1
        while lastVoiced > firstVoiced && abs(samples[lastVoiced]) <= threshold {
            lastVoiced -= 1
        }

        let leadPad = Int(maxLeadingSilenceSeconds * sampleRate)
        let trailPad = Int(maxTrailingSilenceSeconds * sampleRate)
        let start = max(firstVoiced - leadPad, 0)
        let end = min(lastVoiced + 1 + trailPad, count)
        if start == 0 && end == count { return samples }

        var result = Array(samples[start..<end])
        let fade = min(microFadeFrames, result.count / 2)
        if start > 0 && fade > 0 {
            for i in 0..<fade {
                let t = Float(0.5 * (1.0 - cos(Double.pi * Double(i) / Double(fade))))
                result[i] *= t
            }
        }
        if end < count && fade > 0 {
            let tailStart = result.count - fade
            for i in 0..<fade {
                let t = Float(0.5 * (1.0 + cos(Double.pi * Double(i) / Double(fade))))
                result[tailStart + i] *= t
            }
        }
        return result
    }

    private nonisolated static func silence(
        _ count: AVAudioFrameCount,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let data = buffer.floatChannelData else {
            return nil
        }
        data[0].initialize(repeating: 0, count: Int(count))
        buffer.frameLength = count
        return buffer
    }

    /// nil-tolerant concatenation in the canonical format.
    private nonisolated static func concat(
        _ a: AVAudioPCMBuffer?,
        _ b: AVAudioPCMBuffer?
    ) -> AVAudioPCMBuffer? {
        guard let b else { return a }
        guard let a else { return b }
        let total = a.frameLength + b.frameLength
        guard a.format == b.format,
              let out = AVAudioPCMBuffer(pcmFormat: a.format, frameCapacity: total),
              let outData = out.floatChannelData,
              let aData = a.floatChannelData,
              let bData = b.floatChannelData else { return nil }
        outData[0].update(from: aData[0], count: Int(a.frameLength))
        (outData[0] + Int(a.frameLength)).update(from: bData[0], count: Int(b.frameLength))
        out.frameLength = total
        return out
    }

    /// Slice a segment for mid-sentence seek/rate-change, applying a 5 ms
    /// raised-cosine fade-in when `offset > 0` to eliminate waveform clicks.
    nonisolated static func slice(
        _ buffer: AVAudioPCMBuffer,
        from offset: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard offset < buffer.frameLength else { return nil }
        let length = buffer.frameLength - offset
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length),
              let outData = out.floatChannelData,
              let inData = buffer.floatChannelData else { return nil }
        let dest = outData[0]
        dest.update(from: inData[0] + Int(offset), count: Int(length))
        if offset > 0 {
            let fade = min(microFadeFrames, Int(length))
            for i in 0..<fade {
                let t = Float(0.5 * (1.0 - cos(Double.pi * Double(i) / Double(fade))))
                dest[i] *= t
            }
        }
        out.frameLength = length
        return out
    }

    private nonisolated static func decodeBlock(
        _ data: Data,
        pauseFrames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let content = decode(data) else { return nil }
        return concat(silence(pauseFrames, format: content.format), content) ?? content
    }
}
