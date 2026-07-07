import Foundation

/// A voice offered by a provider.
public struct Voice: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Per-voice synthesis settings (ElevenLabs semantics; local providers ignore
/// what they don't support). API speed is intentionally absent: sr pins it at
/// 1.0 and applies rate client-side (F-8), so cached audio stays speed-agnostic.
public struct VoiceSettings: Hashable, Sendable {
    public var stability: Double
    public var similarityBoost: Double
    public var style: Double
    public var useSpeakerBoost: Bool

    public init(stability: Double = 0.5,
                similarityBoost: Double = 0.75,
                style: Double = 0.0,
                useSpeakerBoost: Bool = true) {
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.useSpeakerBoost = useSpeakerBoost
    }
}

/// Result of synthesizing one chunk of text.
public struct SynthesisResult: Sendable {
    /// Complete encoded audio (MP3 for ElevenLabs, WAV for Kokoro).
    public let audio: Data
    /// Provider-side generation identifier, when the provider retains
    /// history (feeds the history janitor, P-6). Nil for local providers.
    public let remoteHistoryItemID: String?

    public init(audio: Data, remoteHistoryItemID: String? = nil) {
        self.audio = audio
        self.remoteHistoryItemID = remoteHistoryItemID
    }
}

public enum TTSError: Error, Sendable {
    case missingAPIKey
    case http(status: Int, body: String?)
    case network(underlying: String)
    case cancelled

    /// Errors that should trigger cloud→local fallback in Auto mode.
    public var isFallbackTrigger: Bool {
        switch self {
        case .http(let status, _): return status == 429 || status >= 500
        case .network: return true
        case .missingAPIKey: return true
        case .cancelled: return false
        }
    }
}

/// Provider abstraction (F-3). One sentence/chunk in, complete audio out.
/// Fast start comes from sentence-level chunking upstream, not from
/// intra-chunk streaming — chunks are a few seconds of audio each.
public protocol TTSProvider: Sendable {
    var id: String { get }
    var isLocal: Bool { get }
    func voices() async throws -> [Voice]
    func synthesize(text: String, voiceID: String, settings: VoiceSettings) async throws -> SynthesisResult
}
