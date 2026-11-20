import Foundation
import Testing
@testable import SRCore

@Suite struct ElevenLabsProviderTests {
    @Test(arguments: ["eleven_v4", "eleven_v4_turbo"])
    func v4PayloadOmitsUnsupportedSettings(model: String) throws {
        let provider = ElevenLabsProvider(modelID: model)
        let data = try provider.synthesisBody(text: "Read this aloud.", settings: VoiceSettings())
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model_id"] as? String == model)
        #expect(body["text"] as? String == "Read this aloud.")
        #expect(body["previous_text"] == nil)
        let settings = try #require(body["voice_settings"] as? [String: Any])
        #expect(Set(settings.keys) == Set(["stability", "similarity_boost"]))
        #expect(settings["stability"] as? Double == 0.5)
        #expect(settings["similarity_boost"] as? Double == 0.75)
    }

    @Test func legacyPayloadRetainsVoiceControls() throws {
        let provider = ElevenLabsProvider(modelID: "eleven_turbo_v2_5")
        let data = try provider.synthesisBody(text: "Read this aloud.", settings: VoiceSettings())
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try #require(body["voice_settings"] as? [String: Any])
        #expect(settings["speed"] as? Double == 1.0)
        #expect(settings["style"] as? Double == 0.0)
        #expect(settings["use_speaker_boost"] as? Bool == true)
    }

    @Test func previousTextIncludedAndBoundedOnWordBoundary() throws {
        let provider = ElevenLabsProvider(modelID: "eleven_v4_turbo")
        let longPrev = String(repeating: "context ", count: 60) // 480 chars
        let data = try provider.synthesisBody(
            text: "Second sentence.",
            settings: VoiceSettings(),
            previousText: longPrev)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let prev = try #require(body["previous_text"] as? String)
        #expect(!prev.isEmpty)
        #expect(prev.count <= ElevenLabsProvider.maxPreviousContextChars)
        #expect(prev.hasPrefix("context"))
    }

    @Test func modelCreditMultipliersMatchPricingTiers() {
        #expect(ElevenLabsProvider.creditMultiplier(for: "eleven_v4_turbo") == 0.5)
        #expect(ElevenLabsProvider.creditMultiplier(for: "eleven_flash_v2_5") == 0.5)
        #expect(ElevenLabsProvider.creditMultiplier(for: "eleven_turbo_v2_5") == 0.5)
        #expect(ElevenLabsProvider.creditMultiplier(for: "eleven_v4") == 1.0)
        #expect(ElevenLabsProvider.creditMultiplier(for: "eleven_multilingual_v2") == 1.0)
        #expect(ElevenLabsProvider.creditMultiplier(for: "eleven_v3") == 1.0)
    }

    @Test func audioQualityFormatsAndCacheNamespace() {
        let standard = ElevenLabsProvider(modelID: "eleven_v4_turbo", audioQuality: .standard)
        let compact = ElevenLabsProvider(modelID: "eleven_v4_turbo", audioQuality: .compact)
        #expect(standard.audioQuality.outputFormat == "mp3_44100_128")
        #expect(compact.audioQuality.outputFormat == "mp3_44100_64")
        #expect(standard.cacheOutputFormat == nil)
        #expect(compact.cacheOutputFormat == "mp3_44100_64")
    }

    @Test func newSettingsDefaultToCostOptimalCloudAndFlagshipLocalVoice() throws {
        let suite = "sr-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        #expect(store.modelID == "eleven_v4_turbo")
        #expect(store.audioQuality == .standard)
        #expect(store.localVoiceID == "af_heart")
        #expect(store.sentencePauseMS == 400)
    }
}
