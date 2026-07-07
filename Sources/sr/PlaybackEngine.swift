@preconcurrency import AVFoundation
import Foundation
import SRCore

/// Timeline audio player with time-domain speed control and seeking
/// (F-7, F-8).
///
/// Speed is applied by stretching PCM with WSOLA (see TimeStretch) at
/// schedule time, not by a realtime phase-vocoder node — phase vocoders
/// (AVAudioUnitTimePitch) smear speech transients into a reverberant
/// "bright room" artifact at higher rates. The graph is therefore just
/// player → mixer in one canonical format (44.1 kHz mono float).
///
/// The content timeline (original 1.0× audio, inter-sentence silence baked
/// in) is kept verbatim; what's scheduled on the player is the stretched
/// rendering at the current rate. Rate changes and seeks re-render from
/// the current content position — segment by segment, off the main thread,
/// so the first re-rendered chunk is audible in tens of milliseconds.
///
/// Positions are tracked in content frames: the player consumes stretched
/// frames, so content position = baseFrame + playedFrames × renderRate.
/// ±5 s seeks therefore mean 5 content-seconds at any rate.
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

    var rate: Double {
        didSet {
            guard abs(rate - oldValue) > 0.001 else { return }
            scheduleRateChange()
        }
    }
    var sentencePauseMS: Int
    var onFinished: (() -> Void)?

    static let sampleRate: Double = 44_100
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: PlaybackEngine.sampleRate, channels: 1)!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // Content timeline (1.0× frames, all in `format`).
    private var segments: [AVAudioPCMBuffer] = []       // one per sentence, leading pause baked in
    private var segmentStartFrames: [AVAudioFramePosition] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var pendingFeeds: [Int: Data] = [:]
    private var appendedCount = 0

    // Playback run state.
    private var renderRate: Double = 1.0                // rate of scheduled audio
    private var baseFrame: AVAudioFramePosition = 0     // content frame at run start
    private var pausedAtFrame: AVAudioFramePosition = 0
    private var outstandingBuffers = 0
    private var generation = 0
    private var uiTimer: Timer?
    private var engineStarted = false
    private var rateChangeWork: DispatchWorkItem?

    /// Serial chain so stretch+schedule ops run in timeline order even
    /// though the stretching happens off the main thread.
    private var chain: Task<Void, Never> = Task {}

    init(rate: Double = 1.0, sentencePauseMS: Int = 400) {
        self.rate = rate
        self.sentencePauseMS = sentencePauseMS
        renderRate = rate

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    var isActive: Bool { state != .idle }

    // MARK: - Session

    func startSession(totalSentences total: Int) {
        stop()
        generation += 1
        totalSentences = total
        renderRate = rate
        state = .playing
        startUITimer()
    }

    /// Deliver audio for sentence `index` (may arrive out of order; the
    /// timeline appends strictly in order).
    func feed(index: Int, audio: Data) {
        guard isActive else { return }
        pendingFeeds[index] = audio
        while let data = pendingFeeds[appendedCount] {
            pendingFeeds[appendedCount] = nil
            append(sentence: appendedCount, data: data)
            appendedCount += 1
        }
    }

    private func append(sentence index: Int, data: Data) {
        let pauseFrames = index == 0 ? 0 : AVAudioFrameCount(
            Double(sentencePauseMS) / 1000.0 * Self.sampleRate)
        let content = decode(data)
        if content == nil {
            SRLog.error("playback.decode_failed", ["index": String(index)])
        }
        // One block per sentence: leading pause + content. A decode failure
        // becomes a 1-frame placeholder so the timeline never stalls.
        guard let block = concat(silence(pauseFrames), content) ?? silence(1) else { return }

        segmentStartFrames.append(totalFrames)
        segments.append(block)
        totalFrames += AVAudioFramePosition(block.frameLength)
        availableSeconds = Double(totalFrames) / Self.sampleRate

        enqueueStretchAndSchedule(block)
    }

    // MARK: - Transport (F-7)

    func pause() {
        guard state == .playing else { return }
        pausedAtFrame = currentFrame
        player.pause()
        state = .paused
        SRLog.event("playback.pause", [:])
    }

    func resume() {
        guard state == .paused else { return }
        ensureEngineRunning()
        player.play()
        state = .playing
        SRLog.event("playback.resume", [:])
    }

    func togglePauseResume() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .idle: break
        }
    }

    func stop() {
        generation += 1
        chain = Task {}
        rateChangeWork?.cancel()
        rateChangeWork = nil
        uiTimer?.invalidate()
        uiTimer = nil
        if engineStarted { player.stop() }
        segments.removeAll()
        segmentStartFrames.removeAll()
        pendingFeeds.removeAll()
        totalFrames = 0
        appendedCount = 0
        baseFrame = 0
        pausedAtFrame = 0
        outstandingBuffers = 0
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

    /// Restart from the top.
    func restart() {
        guard isActive else { return }
        rescheduleContent(from: 0)
    }

    // MARK: - Rendering

    /// Debounced so slider drags don't trigger a re-render per tick.
    private func scheduleRateChange() {
        guard isActive else {
            renderRate = rate
            return
        }
        rateChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isActive else { return }
                self.rescheduleContent(from: self.currentFrame)
            }
        }
        rateChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Stop the player and re-render + re-schedule everything from `target`
    /// (content frames) at the current rate. Used by seek, restart, and
    /// rate changes; also safe while paused (stays paused at the new spot).
    private func rescheduleContent(from target: AVAudioFramePosition) {
        guard totalFrames > 0 else { return }
        let clamped = min(max(0, target), totalFrames - 1)

        generation += 1          // invalidate stale completions and chain ops
        chain = Task {}
        player.stop()            // clears queue; playerTime resets
        outstandingBuffers = 0
        renderRate = rate
        baseFrame = clamped
        pausedAtFrame = clamped

        guard let startSegment = segmentIndex(containing: clamped) else { return }
        let offset = AVAudioFrameCount(clamped - segmentStartFrames[startSegment])
        if let partial = slice(segments[startSegment], from: offset) {
            enqueueStretchAndSchedule(partial)
        }
        for buffer in segments[(startSegment + 1)...] {
            enqueueStretchAndSchedule(buffer)
        }
        updateUIPosition()
    }

    /// Append a stretch+schedule op to the serial chain. Stretching runs
    /// off the main actor; scheduling hops back and is generation-guarded.
    private func enqueueStretchAndSchedule(_ buffer: AVAudioPCMBuffer) {
        let gen = generation
        let rate = renderRate
        let previous = chain
        chain = Task { [weak self] in
            await previous.value
            guard let self, !Task.isCancelled else { return }
            let stretched = await Task.detached(priority: .userInitiated) {
                TimeStretch.stretch(buffer, rate: rate)
            }.value
            await MainActor.run {
                self.scheduleStretched(stretched, generation: gen)
            }
        }
    }

    private func scheduleStretched(_ buffer: AVAudioPCMBuffer, generation gen: Int) {
        guard gen == generation, isActive else { return }
        ensureEngineRunning()
        outstandingBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.outstandingBuffers -= 1
                self.checkFinished()
            }
        }
        if state == .playing, !player.isPlaying {
            player.play()
        }
    }

    // MARK: - Position

    private var currentFrame: AVAudioFramePosition {
        guard state == .playing,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return pausedAtFrame
        }
        let contentAdvance = AVAudioFramePosition(
            Double(playerTime.sampleTime) * renderRate)
        return min(baseFrame + contentAdvance, totalFrames)
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

    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
    }

    private func checkFinished() {
        guard state == .playing,
              totalSentences > 0,
              appendedCount >= totalSentences,
              outstandingBuffers == 0 else { return }
        let n = totalSentences
        stop()
        SRLog.event("playback.finished", ["sentences": String(n)])
        onFinished?()
    }

    // MARK: - Engine / decode

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            engineStarted = true
        } catch {
            SRLog.error("playback.engine_start", ["error": String(describing: error)])
        }
    }

    /// Decode MP3/WAV Data → canonical 44.1 kHz mono float buffer.
    private func decode(_ data: Data) -> AVAudioPCMBuffer? {
        // AVAudioFile needs a URL; write to a private temp file with a
        // random name (never content-derived), delete immediately after.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-\(UUID().uuidString).audio")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .completeFileProtection)
            let file = try AVAudioFile(forReading: url)
            guard let raw = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: raw)
            return convert(raw, to: format)
        } catch {
            SRLog.error("playback.decode", ["error": String(describing: type(of: error))])
            return nil
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: target) else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    private func silence(_ count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            return nil
        }
        buffer.frameLength = count  // float buffers zero-initialize = silence
        return buffer
    }

    /// nil-tolerant concatenation in the canonical format.
    private func concat(_ a: AVAudioPCMBuffer?, _ b: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard let b else { return a }
        guard let a else { return b }
        let total = a.frameLength + b.frameLength
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let outData = out.floatChannelData,
              let aData = a.floatChannelData,
              let bData = b.floatChannelData else { return nil }
        outData[0].update(from: aData[0], count: Int(a.frameLength))
        (outData[0] + Int(a.frameLength)).update(from: bData[0], count: Int(b.frameLength))
        out.frameLength = total
        return out
    }

    private func slice(_ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard offset < buffer.frameLength else { return nil }
        let length = buffer.frameLength - offset
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let outData = out.floatChannelData,
              let inData = buffer.floatChannelData else { return nil }
        outData[0].update(from: inData[0] + Int(offset), count: Int(length))
        out.frameLength = length
        return out
    }
}
