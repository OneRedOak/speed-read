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
    /// Exact billed credits from the provider (`character-cost` header),
    /// feeding the cost ledger (C-1/C-2). Nil for local providers.
    public let billedCharacters: Int?

    public init(audio: Data, remoteHistoryItemID: String? = nil, billedCharacters: Int? = nil) {
        self.audio = audio
        self.remoteHistoryItemID = remoteHistoryItemID
        self.billedCharacters = billedCharacters
    }
}

public enum TTSError: Error, Sendable {
    case missingAPIKey
    case http(status: Int, body: String?)
    /// A billed HTTP-200 response whose body was not decodable audio. Carry
    /// provider metadata so cost accounting and optional history deletion
    /// still happen before fallback/failure handling.
    case invalidAudio(historyItemID: String?, billedCharacters: Int?)
    case network(underlying: String)
    case budgetExceeded
    case cancelled

    /// Errors that should trigger cloud→local fallback in Auto mode.
    public var isFallbackTrigger: Bool {
        switch self {
        case .http(let status, _): return status == 429 || status >= 500
        case .invalidAudio: return true
        case .network: return true
        case .missingAPIKey: return true
        case .budgetExceeded, .cancelled: return false
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

// Error payloads can contain provider-echoed text, URLs, or history IDs.
// Only these fixed categories and numeric HTTP status codes may enter logs.
extension TTSError {
    public var logCategory: String {
        switch self {
        case .missingAPIKey: return "missing_api_key"
        case .http(let status, _): return "http_\(status)"
        case .invalidAudio: return "invalid_audio"
        case .network: return "network"
        case .budgetExceeded: return "budget_exceeded"
        case .cancelled: return "cancelled"
        }
    }
}
