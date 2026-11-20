import AVFoundation
import Foundation
import SRCore
import Testing
@testable import sr

private actor ContextCapturingCloudProvider: TTSProvider {
    nonisolated let id = "context-cloud"
    nonisolated let isLocal = false
    nonisolated let creditMultiplier: Double = 0.5
    private(set) var calls: [(text: String, previousText: String?)] = []

    func voices() async throws -> [Voice] { [] }

    func synthesize(text: String, voiceID: String, settings: VoiceSettings) async throws -> SynthesisResult {
        try await synthesize(text: text, voiceID: voiceID, settings: settings, previousText: nil)
    }

    func synthesize(
        text: String,
        voiceID: String,
        settings: VoiceSettings,
        previousText: String?
    ) async throws -> SynthesisResult {
        calls.append((text, previousText))
        return SynthesisResult(audio: Data([0xFF, 0xFB, 0x90, 0x64]), billedCharacters: text.count / 2)
    }
}

private actor OrderedLocalProvider: TTSProvider {
    nonisolated let id = "ordered-local"
    nonisolated let isLocal = true
    private(set) var maxSimultaneous = 0
    private var active = 0
    private(set) var startedOrder: [String] = []

    func voices() async throws -> [Voice] { [] }

    func synthesize(text: String, voiceID: String, settings: VoiceSettings) async throws -> SynthesisResult {
        active += 1
        maxSimultaneous = max(maxSimultaneous, active)
        startedOrder.append(text)
        try? await Task.sleep(for: .milliseconds(25))
        active -= 1
        return SynthesisResult(audio: Data([0x52, 0x49, 0x46, 0x46]))
    }
}

@Suite struct PlaybackAndPipelineTests {
    /// Build a minimal valid 16-bit PCM mono WAV in memory (no disk I/O).
    private func makeWAV(sampleRate: UInt32 = 24_000, samples: [Int16]) -> Data {
        let dataBytes = UInt32(samples.count * 2)
        let riffSize = UInt32(36 + dataBytes)
        var wav = Data()
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            wav.append(Data(bytes: &le, count: MemoryLayout<T>.size))
        }
        wav.append(contentsOf: "RIFF".utf8)
        appendLE(riffSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))             // PCM chunk size
        appendLE(UInt16(1))              // PCM format
        appendLE(UInt16(1))              // mono
        appendLE(sampleRate)
        appendLE(sampleRate * 2)         // byte rate
        appendLE(UInt16(2))              // block align
        appendLE(UInt16(16))             // bits per sample
        wav.append(contentsOf: "data".utf8)
        appendLE(dataBytes)
        for s in samples { appendLE(s) }
        return wav
    }

    @Test func inMemoryWAVDecodeResamplesTo44100MonoWithoutTempFiles() throws {
        // 0.25 s 440 Hz tone at 24 kHz (Kokoro's native sample rate).
        let sr = 24_000.0
        let count = Int(sr * 0.25)
        let pcm: [Int16] = (0..<count).map { i in
            let v = sin(2.0 * .pi * 440.0 * Double(i) / sr) * 0.5
            return Int16(v * Double(Int16.max))
        }
        let wav = makeWAV(sampleRate: 24_000, samples: pcm)
        let decoded = try #require(PlaybackEngine.decode(wav))
        #expect(decoded.format.sampleRate == PlaybackEngine.sampleRate)
        #expect(decoded.format.channelCount == 1)
        let expectedFrames = Int(0.25 * PlaybackEngine.sampleRate)
        #expect(abs(Int(decoded.frameLength) - expectedFrames) < 1024)
    }

    @Test func edgeSilenceTrimCapsDeadAirAndPreservesPureSilence() {
        let sr = Int(PlaybackEngine.sampleRate)
        // 0.4 s silence + 0.5 s speech + 0.5 s silence = 1.4 s total.
        let lead = [Float](repeating: 0, count: Int(Double(sr) * 0.4))
        let speech = [Float](repeating: 0.4, count: Int(Double(sr) * 0.5))
        let trail = [Float](repeating: 0, count: Int(Double(sr) * 0.5))
        let trimmed = PlaybackEngine.trimExcessiveEdgeSilence(lead + speech + trail)
        // Expected: ~0.035 s lead + 0.5 s speech + 0.060 s trail ≈ 0.595 s.
        let expected = Int(Double(sr) * (0.035 + 0.5 + 0.060))
        #expect(abs(trimmed.count - expected) < 64)
        // Edge micro-fades start and end at ~0 to prevent clicks.
        #expect(abs(trimmed[0]) < 0.01)
        #expect(abs(trimmed[trimmed.count - 1]) < 0.01)

        // All-silent audio must pass through untouched.
        let pureSilence = [Float](repeating: 0, count: 4410)
        #expect(PlaybackEngine.trimExcessiveEdgeSilence(pureSilence).count == 4410)
    }

    @Test func midSegmentSliceAppliesDeClickFadeIn() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: PlaybackEngine.sampleRate, channels: 1)!
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000))
        buf.frameLength = 4000
        let ptr = buf.floatChannelData![0]
        for i in 0..<4000 { ptr[i] = 0.8 }

        let sliced = try #require(PlaybackEngine.slice(buf, from: 1000))
        let outPtr = sliced.floatChannelData![0]
        #expect(sliced.frameLength == 3000)
        // First sample ramped to ~0, settled back to 0.8 after 5 ms fade.
        #expect(abs(outPtr[0]) < 0.01)
        #expect(abs(outPtr[500] - 0.8) < 0.001)
    }

    @Test func scheduledSpansMapRenderedTimeWithoutCumulativeDrift() {
        // Two segments whose WSOLA-rendered lengths intentionally deviate from
        // exact contentLength / 2.0 (simulating hop/tail quantization).
        let spans = [
            ScheduledSpan(contentStart: 0, contentLength: 44_100, renderedStart: 0, renderedLength: 23_100),
            ScheduledSpan(contentStart: 44_100, contentLength: 88_200, renderedStart: 23_100, renderedLength: 45_000),
        ]
        // Exact boundary between segment 0 and segment 1:
        let atBoundary = PlaybackEngine.contentFrame(
            forRenderedSample: 23_100, in: spans, totalFrames: 132_300)
        #expect(atBoundary == 44_100)
        // Midpoint of segment 1:
        let midSecond = PlaybackEngine.contentFrame(
            forRenderedSample: 23_100 + 22_500, in: spans, totalFrames: 132_300)
        #expect(midSecond == 44_100 + 44_100)
    }

    @Test @MainActor func cloudPipelinePassesPreviousTextOnlyAndRespectsMultiplierBudget() async {
        let provider = ContextCapturingCloudProvider()
        let pipeline = SynthesisPipeline()
        defer { pipeline.cancel() }

        let chunks = [
            Chunk(id: 0, text: "First sentence of twenty.", offset: 0),
            Chunk(id: 1, text: "Second sentence follows.", offset: 26),
        ]
        // 25 + 24 = 49 chars; at 0.5× credit multiplier, budget of 30 suffices!
        var deliveredCount = 0
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pipeline.run(
                chunks: chunks,
                primary: .init(provider: provider, voiceID: "v", modelID: "eleven_v4_turbo"),
                fallback: nil,
                settings: VoiceSettings(),
                cache: nil,
                cloudBudgetRemaining: 30,
                callbacks: .init(
                    deliver: { _, _ in
                        deliveredCount += 1
                        if deliveredCount == 2 { cont.resume() }
                    },
                    billed: { _ in },
                    historyID: { _ in },
                    fellBack: {},
                    failed: { err in
                        Issue.record("unexpected failure: \(err)")
                        cont.resume()
                    }))
        }

        let calls = await provider.calls
        let first = calls.first { $0.text == chunks[0].text }
        let second = calls.first { $0.text == chunks[1].text }
        #expect(first?.previousText == nil)
        #expect(second?.previousText == chunks[0].text)
    }

    @Test @MainActor func localPipelineSerializesInStrictChunkOrder() async {
        let provider = OrderedLocalProvider()
        let pipeline = SynthesisPipeline()
        defer { pipeline.cancel() }

        let chunks = (0..<4).map { Chunk(id: $0, text: "chunk-\($0)", offset: $0 * 8) }
        var deliveredCount = 0
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pipeline.run(
                chunks: chunks,
                primary: .init(provider: provider, voiceID: "af_heart", modelID: "kokoro"),
                fallback: nil,
                settings: VoiceSettings(),
                cache: nil,
                callbacks: .init(
                    deliver: { _, _ in
                        deliveredCount += 1
                        if deliveredCount == chunks.count { cont.resume() }
                    },
                    billed: { _ in },
                    historyID: { _ in },
                    fellBack: {},
                    failed: { err in
                        Issue.record("unexpected failure: \(err)")
                        cont.resume()
                    }))
        }

        #expect(await provider.maxSimultaneous == 1)
        #expect(await provider.startedOrder == ["chunk-0", "chunk-1", "chunk-2", "chunk-3"])
    }
}
