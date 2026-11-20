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
        static let audioQuality = "audioQuality"
        static let playbackRate = "playbackRate"
        static let sentencePauseMS = "sentencePauseMS"
        static let stability = "stability"
        static let similarityBoost = "similarityBoost"
        static let style = "style"
        static let useSpeakerBoost = "useSpeakerBoost"
        static let autoDeleteHistory = "autoDeleteHistory"
        static let cacheEnabled = "cacheEnabled"
        static let backendMode = "backendMode"
        static let localVoiceID = "localVoiceID"
    }

    /// Backend modes (F-3): Auto = cloud with local fallback.
    public enum BackendMode: String, CaseIterable, Sendable {
        case auto, cloud, local
    }

    public var voiceID: String {
        get { defaults.string(forKey: Key.voiceID) ?? ElevenLabsProvider.presetVoices[0].id }
        nonmutating set { defaults.set(newValue, forKey: Key.voiceID) }
    }

    public var modelID: String {
        get { defaults.string(forKey: Key.modelID) ?? ElevenLabsProvider.defaultModelID }
        nonmutating set { defaults.set(newValue, forKey: Key.modelID) }
    }

    public var audioQuality: ElevenLabsProvider.AudioQuality {
        get {
            ElevenLabsProvider.AudioQuality(
                rawValue: defaults.string(forKey: Key.audioQuality) ?? ""
            ) ?? .standard
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.audioQuality) }
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
            guard defaults.object(forKey: Key.sentencePauseMS) != nil else { return 400 }
            return min(max(defaults.integer(forKey: Key.sentencePauseMS), 0), 1500)
        }
        nonmutating set { defaults.set(min(max(newValue, 0), 1500), forKey: Key.sentencePauseMS) }
    }

    /// ElevenLabs history auto-delete (P-6). ON by default.
    public var autoDeleteHistory: Bool {
        get {
            defaults.object(forKey: Key.autoDeleteHistory) == nil
                ? true : defaults.bool(forKey: Key.autoDeleteHistory)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.autoDeleteHistory) }
    }

    /// Audio cache toggle; off = "sensitive session" mode (P-10).
    public var cacheEnabled: Bool {
        get {
            defaults.object(forKey: Key.cacheEnabled) == nil
                ? true : defaults.bool(forKey: Key.cacheEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.cacheEnabled) }
    }

    /// Backend mode; `local` doubles as the Local-Only master switch (P-8).
    public var backendMode: BackendMode {
        get {
            BackendMode(rawValue: defaults.string(forKey: Key.backendMode) ?? "") ?? .auto
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.backendMode) }
    }

    /// Default to Heart (`af_heart`), Kokoro v1.0's flagship voice; existing
    /// saved local voice preferences are preserved.
    public var localVoiceID: String {
        get { defaults.string(forKey: Key.localVoiceID) ?? KokoroProvider.presetVoices[0].id }
        nonmutating set { defaults.set(newValue, forKey: Key.localVoiceID) }
    }

    public var voiceSettings: VoiceSettings {
        get {
            VoiceSettings(
                stability: defaults.object(forKey: Key.stability) == nil
                    ? 0.5 : min(max(defaults.double(forKey: Key.stability), 0.0), 1.0),
                similarityBoost: defaults.object(forKey: Key.similarityBoost) == nil
                    ? 0.75 : min(max(defaults.double(forKey: Key.similarityBoost), 0.0), 1.0),
                style: min(max(defaults.double(forKey: Key.style), 0.0), 1.0),
                useSpeakerBoost: defaults.object(forKey: Key.useSpeakerBoost) == nil
                    ? true : defaults.bool(forKey: Key.useSpeakerBoost)
            )
        }
        nonmutating set {
            defaults.set(min(max(newValue.stability, 0.0), 1.0), forKey: Key.stability)
            defaults.set(min(max(newValue.similarityBoost, 0.0), 1.0), forKey: Key.similarityBoost)
            defaults.set(min(max(newValue.style, 0.0), 1.0), forKey: Key.style)
            defaults.set(newValue.useSpeakerBoost, forKey: Key.useSpeakerBoost)
        }
    }
}
