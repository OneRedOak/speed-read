import Foundation

/// Non-secret preferences in UserDefaults (com.patrickellis.sr).
/// Secrets live in the Keychain only (P-1).
public struct SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let voiceID = "voiceID"
        static let modelID = "modelID"
        static let playbackRate = "playbackRate"
        static let sentencePauseMS = "sentencePauseMS"
        static let stability = "stability"
        static let similarityBoost = "similarityBoost"
        static let style = "style"
        static let useSpeakerBoost = "useSpeakerBoost"
    }

    public var voiceID: String {
        get { defaults.string(forKey: Key.voiceID) ?? ElevenLabsProvider.presetVoices[0].id }
        nonmutating set { defaults.set(newValue, forKey: Key.voiceID) }
    }

    public var modelID: String {
        get { defaults.string(forKey: Key.modelID) ?? ElevenLabsProvider.defaultModelID }
        nonmutating set { defaults.set(newValue, forKey: Key.modelID) }
    }

    /// Client-side playback rate, 0.5–3.0 (F-8).
    public var playbackRate: Double {
        get {
            let v = defaults.double(forKey: Key.playbackRate)
            return v == 0 ? 1.0 : min(max(v, 0.5), 3.0)
        }
        nonmutating set { defaults.set(min(max(newValue, 0.5), 3.0), forKey: Key.playbackRate) }
    }

    /// Inter-sentence pause in ms at 1.0× (scales inversely with rate, F-5).
    public var sentencePauseMS: Int {
        get {
            defaults.object(forKey: Key.sentencePauseMS) == nil
                ? 400 : defaults.integer(forKey: Key.sentencePauseMS)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.sentencePauseMS) }
    }

    public var voiceSettings: VoiceSettings {
        get {
            VoiceSettings(
                stability: defaults.object(forKey: Key.stability) == nil
                    ? 0.5 : defaults.double(forKey: Key.stability),
                similarityBoost: defaults.object(forKey: Key.similarityBoost) == nil
                    ? 0.75 : defaults.double(forKey: Key.similarityBoost),
                style: defaults.double(forKey: Key.style),
                useSpeakerBoost: defaults.object(forKey: Key.useSpeakerBoost) == nil
                    ? true : defaults.bool(forKey: Key.useSpeakerBoost)
            )
        }
        nonmutating set {
            defaults.set(newValue.stability, forKey: Key.stability)
            defaults.set(newValue.similarityBoost, forKey: Key.similarityBoost)
            defaults.set(newValue.style, forKey: Key.style)
            defaults.set(newValue.useSpeakerBoost, forKey: Key.useSpeakerBoost)
        }
    }
}
