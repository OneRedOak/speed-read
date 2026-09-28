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
}
