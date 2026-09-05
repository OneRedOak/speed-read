import Foundation
import SRCore
import Testing
@testable import sr

private actor PrefetchProvider: TTSProvider {
    nonisolated let id = "prefetch-test"
    nonisolated let isLocal = false
    private(set) var requests = 0
    func voices() async throws -> [Voice] { [] }
    func synthesize(text: String, voiceID: String, settings: VoiceSettings) async throws -> SynthesisResult {
        requests += 1
        return SynthesisResult(audio: Data([1]), billedCharacters: 1)
    }
}

@Suite @MainActor struct PrefetchTests {
    @Test func readAheadFollowsPlaybackAndStopsDuringPauseAndCancellation() async throws {
        let provider = PrefetchProvider()
        let pipeline = SynthesisPipeline()
        defer { pipeline.cancel() }
        final class Playhead {
            var sentence = 0
            var playing = true
            var delivered = 0
        }
        let playhead = Playhead()
        pipeline.run(
            chunks: (0..<30).map { Chunk(id: $0, text: "sentence \($0)", offset: 0) },
            primary: .init(provider: provider, voiceID: "v", modelID: "m"),
            fallback: nil, settings: VoiceSettings(), cache: nil,
            shouldSynthesize: { index in
                SynthesisPipeline.needsChunk(index, currentSentence: playhead.sentence,
                                             isPlaying: playhead.playing)
            },
            callbacks: .init(deliver: { _, _ in playhead.delivered += 1 },
                             billed: { _ in }, historyID: { _ in }, fellBack: {},
                             failed: { _ in Issue.record("unexpected synthesis failure") }))
        let deadline = Date().addingTimeInterval(3)
        while playhead.delivered < 6 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(playhead.delivered == 6)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await provider.requests == 6) // fast provider cannot race through the article
        playhead.playing = false
        playhead.sentence = 1
        try await Task.sleep(for: .milliseconds(300))
        #expect(await provider.requests == 6)
        playhead.playing = true
        let resumeDeadline = Date().addingTimeInterval(3)
        while playhead.delivered < 7 && Date() < resumeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(playhead.delivered == 7)
        pipeline.cancel()
        playhead.sentence = 29
        try await Task.sleep(for: .milliseconds(300))
        #expect(await provider.requests == 7)
    }
}
