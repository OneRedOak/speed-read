@preconcurrency import AVFoundation
import Foundation
import SRCore

/// Timeline audio player with pitch-preserving client-side speed and
/// time-based seeking (F-7, F-8).
///
/// All audio is decoded into ONE canonical PCM format (44.1 kHz mono
/// float) appended to a continuous timeline, and the graph
/// player → timePitch → mixer is connected in that same format. A single
/// format end to end matters: scheduling buffers whose sample rate differs
/// from the connection's makes CoreAudio play them at the wrong speed AND
/// the wrong pitch — the "faster gets higher and muddier" bug. The old
/// engine wired the graph with whatever format the mixer reported at init
/// and decoded against whatever it reported later, which can differ
/// (44.1 kHz vs the output device's 48 kHz).
///
/// Rate 0.5–3.0× via AVAudioUnitTimePitch (pitch locked, overlap raised
/// for cleaner high-rate output). Inter-sentence pauses are baked into the
/// timeline as silence sized at 1.0×, so they shrink proportionally at
/// higher rates — the same inverse pause/rate behavior Speak11 computed.
///
/// Seeking: position is tracked in content frames (playerTime advances in
/// content time regardless of rate), so ±5 s means 5 content-seconds.
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
        didSet { timePitch.rate = Float(rate) }
    }
    var sentencePauseMS: Int
    var onFinished: (() -> Void)?

    static let sampleRate: Double = 44_100
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: PlaybackEngine.sampleRate, channels: 1)!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    // Timeline (content frames, all in `format`).
    private var segments: [AVAudioPCMBuffer] = []       // one per sentence, leading pause baked in
    private var segmentStartFrames: [AVAudioFramePosition] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var pendingFeeds: [Int: Data] = [:]
    private var appendedCount = 0

    /// Content-frame position where the current player run began (set on
    /// every seek; playerTime restarts at 0 after each player.stop()).
    private var baseFrame: AVAudioFramePosition = 0
    private var pausedAtFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var uiTimer: Timer?
    private var engineStarted = false

    init(rate: Double = 1.0, sentencePauseMS: Int = 400) {
        self.rate = rate
        self.sentencePauseMS = sentencePauseMS

        engine.attach(player)
        engine.attach(timePitch)
        timePitch.rate = Float(rate)
        timePitch.pitch = 0
        timePitch.overlap = 16  // higher windowing quality than the default 8

        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    var isActive: Bool { state != .idle }

    // MARK: - Session

    func startSession(totalSentences total: Int) {
        stop()
        generation += 1
        totalSentences = total
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
        let block = concat(silence(pauseFrames), content) ?? silence(1)
        guard let block else { return }

        segmentStartFrames.append(totalFrames)
        segments.append(block)
        totalFrames += AVAudioFramePosition(block.frameLength)
        availableSeconds = Double(totalFrames) / Self.sampleRate

        ensureEngineRunning()
        let gen = generation
        player.scheduleBuffer(block) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.checkFinished()
            }
        }
        if state == .playing, !player.isPlaying {
            player.play()
        }
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
        seek(toFrame: currentFrame + delta)
    }

    /// Restart from the top.
    func restart() {
        guard isActive else { return }
        seek(toFrame: 0)
    }

    private func seek(toFrame target: AVAudioFramePosition) {
        guard totalFrames > 0 else { return }
        let clamped = min(max(0, target), totalFrames - 1)
        let wasPlaying = state == .playing

        generation += 1  // invalidate completion callbacks of cleared buffers
        player.stop()    // clears the scheduled queue; playerTime resets

        guard let startSegment = segmentIndex(containing: clamped) else { return }
        let gen = generation
        let offset = AVAudioFrameCount(clamped - segmentStartFrames[startSegment])

        var toSchedule: [AVAudioPCMBuffer] = []
        if let partial = slice(segments[startSegment], from: offset) {
            toSchedule.append(partial)
        }
        toSchedule.append(contentsOf: segments[(startSegment + 1)...])
        for buffer in toSchedule {
            player.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.checkFinished()
                }
            }
        }

        baseFrame = clamped
        pausedAtFrame = clamped
        if wasPlaying {
            ensureEngineRunning()
            player.play()
        }
        updateUIPosition()
        SRLog.event("playback.seek", ["to_s": String(Int(Double(clamped) / Self.sampleRate))])
    }

    // MARK: - Position

    private var currentFrame: AVAudioFramePosition {
        guard state == .playing,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return pausedAtFrame
        }
        return min(baseFrame + playerTime.sampleTime, totalFrames)
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
                self?.checkFinished()
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
              currentFrame >= totalFrames - 10 else { return }
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
