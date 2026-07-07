@preconcurrency import AVFoundation
import Foundation
import SRCore

/// Sentence-queue audio player with client-side, pitch-preserving speed
/// (F-7 partial, F-8).
///
/// Chain: AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer → output.
/// Rate 0.5–3.0× applies live to current and queued audio; the API always
/// generates at 1.0×, so nothing is ever regenerated for a speed change.
///
/// Inter-sentence pause (default 400 ms) scales inversely with rate,
/// matching Speak11's behavior.
@MainActor
final class PlaybackEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case playing(sentence: Int, of: Int)
        case paused(sentence: Int, of: Int)
    }

    @Published private(set) var state: State = .idle

    var rate: Double {
        didSet {
            timePitch.rate = Float(rate)
        }
    }
    var sentencePauseMS: Int

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    /// Decoded sentences in order. Index == Chunk.id.
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var totalSentences = 0
    private var nextToSchedule = 0
    private var finishedCount = 0
    /// Incremented on stop; stale completion callbacks check it.
    private var generation = 0
    private var pendingPauseWork: DispatchWorkItem?
    private var engineStarted = false

    var onFinished: (() -> Void)?

    init(rate: Double = 1.0, sentencePauseMS: Int = 400) {
        self.rate = rate
        self.sentencePauseMS = sentencePauseMS

        engine.attach(player)
        engine.attach(timePitch)
        timePitch.rate = Float(rate)
        timePitch.pitch = 0  // preserve pitch at all rates

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Session control

    /// Begin a new utterance of `total` sentences. Buffers arrive via feed().
    func startSession(totalSentences total: Int) {
        stop()
        generation += 1
        totalSentences = total
        state = .playing(sentence: 0, of: total)
    }

    /// Deliver decoded audio for sentence `index`. Buffers may arrive out of
    /// order from the bounded-concurrency pipeline; scheduling is in-order.
    func feed(index: Int, audio: Data) {
        guard isActive else { return }
        if let pcm = decode(audio) {
            buffers[index] = pcm
        } else if let silent = silentBuffer() {
            SRLog.error("playback.decode_failed", ["index": String(index)])
            // Substitute a near-empty buffer so the in-order queue never stalls.
            buffers[index] = silent
        } else {
            // Pathological: no decodable audio and no silent buffer. Count the
            // sentence as done so the session can still finish.
            SRLog.error("playback.decode_failed", ["index": String(index)])
            if index == nextToSchedule {
                nextToSchedule += 1
                sentenceFinished()
            }
        }
        scheduleReady()
    }

    func pause() {
        guard case .playing(let s, let n) = state else { return }
        pendingPauseWork?.cancel()
        player.pause()
        state = .paused(sentence: s, of: n)
        SRLog.event("playback.pause", [:])
    }

    func resume() {
        guard case .paused(let s, let n) = state else { return }
        ensureEngineRunning()
        player.play()
        state = .playing(sentence: s, of: n)
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
        pendingPauseWork?.cancel()
        pendingPauseWork = nil
        if engineStarted {
            player.stop()
        }
        buffers.removeAll()
        totalSentences = 0
        nextToSchedule = 0
        finishedCount = 0
        state = .idle
    }

    var isActive: Bool { state != .idle }

    // MARK: - Internals

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            engineStarted = true
        } catch {
            SRLog.error("playback.engine_start", ["error": String(describing: error)])
        }
    }

    private func scheduleReady() {
        while let buffer = buffers[nextToSchedule] {
            let index = nextToSchedule
            buffers[index] = nil
            nextToSchedule += 1
            schedule(buffer: buffer, index: index)
        }
    }

    private func silentBuffer() -> AVAudioPCMBuffer? {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        buffer?.frameLength = 1
        return buffer
    }

    private func schedule(buffer: AVAudioPCMBuffer, index: Int) {
        ensureEngineRunning()
        let gen = generation

        let startPlayback = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.player.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.sentenceFinished()
                }
            }
            if case .playing = self.state {
                self.player.play()
            }
            if case .playing(_, let n) = self.state {
                self.state = .playing(sentence: index, of: n)
            }
        }

        // Inter-sentence pause before every sentence except the first,
        // scaled inversely with playback rate.
        if index > 0 && sentencePauseMS > 0 {
            let delay = Double(sentencePauseMS) / 1000.0 / rate
            let work = DispatchWorkItem(block: startPlayback)
            pendingPauseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            startPlayback()
        }
    }

    private func sentenceFinished() {
        finishedCount += 1
        if finishedCount >= totalSentences && totalSentences > 0 {
            let n = totalSentences
            stop()
            SRLog.event("playback.finished", ["sentences": String(n)])
            onFinished?()
        }
    }

    /// Decode MP3 (or WAV) Data into a PCM buffer in the mixer format.
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
            return convert(raw, to: engine.mainMixerNode.outputFormat(forBus: 0))
        } catch {
            SRLog.error("playback.decode", ["error": String(describing: type(of: error))])
            return nil
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
}
