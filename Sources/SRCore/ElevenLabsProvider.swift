import Foundation

/// ElevenLabs cloud provider (F-3).
///
/// Network endpoints (P-11 allowlist): api.elevenlabs.io only.
/// Uses an ephemeral URLSession (no disk URLCache, no persistent cookies)
/// with connection pooling for HTTP/2 reuse.
/// Playback rate is client-side (F-8); legacy API speed is pinned at 1.0.
public struct ElevenLabsProvider: TTSProvider {
    public let id = "elevenlabs"
    public let isLocal = false

    public static let defaultModelID = "eleven_v4_turbo"
    public static let outputFormat = "mp3_44100_128"
    /// Maximum trailing characters from the previous sentence sent as free
    /// `previous_text` prosody context (0 extra credits).
    public static let maxPreviousContextChars = 250

    /// Output audio quality / bandwidth trade-off. Both options keep 44.1 kHz
    /// (matching PlaybackEngine natively with zero resampling) and cost the
    /// exact same credits on ElevenLabs.
    public enum AudioQuality: String, CaseIterable, Sendable {
        case standard   // mp3_44100_128 — transparent speech fidelity (default)
        case compact    // mp3_44100_64  — 50% smaller transfer & cache

        public var outputFormat: String {
            switch self {
            case .standard: return "mp3_44100_128"
            case .compact: return "mp3_44100_64"
            }
        }

        public var label: String {
            switch self {
            case .standard: return "Standard (128 kbps)"
            case .compact: return "Compact (64 kbps — saves bandwidth)"
            }
        }
    }

    public struct ModelInfo: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let shortName: String
        /// Credits consumed per character (0.5 for Turbo/Flash, 1.0 for flagship).
        public let creditMultiplier: Double

        /// Compact display label that fits cleanly without ellipsis in the menu bar.
        public var compactLabel: String {
            let tier = creditMultiplier < 1.0 ? "0.5× credits" : "1× credits"
            return "\(shortName) · \(tier)"
        }
    }

    public static let modelCatalog: [ModelInfo] = [
        ModelInfo(id: "eleven_v4_turbo", name: "v4 Turbo — recommended (0.5× credits)",
                  shortName: "v4 Turbo", creditMultiplier: 0.5),
        ModelInfo(id: "eleven_v4", name: "v4 — highest quality (1× credits)",
                  shortName: "v4", creditMultiplier: 1.0),
        ModelInfo(id: "eleven_flash_v2_5", name: "Flash v2.5 — ultra-fast (0.5× credits)",
                  shortName: "Flash v2.5", creditMultiplier: 0.5),
        ModelInfo(id: "eleven_turbo_v2_5", name: "Turbo v2.5 — legacy (0.5× credits)",
                  shortName: "Turbo v2.5", creditMultiplier: 0.5),
        ModelInfo(id: "eleven_multilingual_v2", name: "Multilingual v2 — long-form (1× credits)",
                  shortName: "Multilingual v2", creditMultiplier: 1.0),
        ModelInfo(id: "eleven_v3", name: "v3 — expressive (1× credits)",
                  shortName: "v3", creditMultiplier: 1.0),
    ]

    public static let models: [(name: String, id: String)] =
        modelCatalog.map { ($0.name, $0.id) }

    public static func modelInfo(for id: String) -> ModelInfo? {
        modelCatalog.first { $0.id == id }
    }

    public static func creditMultiplier(for modelID: String) -> Double {
        modelInfo(for: modelID)?.creditMultiplier ?? 1.0
    }

    /// Ephemeral session: zero disk URLCache / persistent cookies (privacy),
    /// with a dedicated connection pool for HTTP/2 reuse against api.elevenlabs.io.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Bootstrap fallback only — the picker fetches the account's real voice
    /// list (F-10). The reference repo's wider preset list included library
    /// voices that 402 on free plans ("paid_plan_required"); these three are
    /// standard premade voices present on every account.
    public static let presetVoices: [Voice] = [
        Voice(id: "pFZP5JQG7iQjIQuC4Bku", name: "Lily — velvety actress"),
        Voice(id: "Xb7hH8MSUJpSbSDYk0k2", name: "Alice — clear educator"),
        Voice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam — dominant, firm"),
    ]

    public var modelID: String
    public var audioQuality: AudioQuality

    public var creditMultiplier: Double {
        Self.creditMultiplier(for: modelID)
    }

    public var cacheOutputFormat: String? {
        audioQuality == .standard ? nil : audioQuality.outputFormat
    }

    public init(
        modelID: String = ElevenLabsProvider.defaultModelID,
        audioQuality: AudioQuality = .standard
    ) {
        self.modelID = modelID
        self.audioQuality = audioQuality
    }

    public func voices() async throws -> [Voice] {
        guard let key = KeychainStore.readAPIKey() else { throw TTSError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401 || status == 403 { KeychainStore.invalidateCache() }
            throw TTSError.http(status: status, body: nil)
        }
        struct VoiceList: Decodable {
            struct V: Decodable {
                let voice_id: String
                let name: String
            }
            let voices: [V]
        }
        let list = try JSONDecoder().decode(VoiceList.self, from: data)
        return list.voices.map { Voice(id: $0.voice_id, name: $0.name) }
    }

    /// Normalize optional trailing context from the preceding sentence so
    /// prosody flows smoothly across sentence boundaries at zero extra credits.
    public static func trimmedPreviousContext(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxPreviousContextChars { return trimmed }
        let suffix = trimmed.suffix(maxPreviousContextChars)
        if let space = suffix.firstIndex(where: { $0.isWhitespace }) {
            let afterSpace = suffix[suffix.index(after: space)...]
            if !afterSpace.isEmpty { return String(afterSpace) }
        }
        return String(suffix)
    }

    /// v4 supports only stability and similarity; omit legacy-only fields.
    /// Kept separate from transport so the actual wire payload is testable.
    func synthesisBody(
        text: String,
        settings: VoiceSettings,
        previousText: String? = nil
    ) throws -> Data {
        let isV4 = modelID == "eleven_v4" || modelID == "eleven_v4_turbo"
        struct Body: Encodable {
            struct Settings: Encodable {
                let stability: Double
                let similarity_boost: Double
                let style: Double?
                let use_speaker_boost: Bool?
                let speed: Double?
            }
            let text: String
            let model_id: String
            let voice_settings: Settings
            let previous_text: String?
        }
        return try JSONEncoder().encode(Body(
            text: text,
            model_id: modelID,
            voice_settings: .init(
                stability: settings.stability,
                similarity_boost: settings.similarityBoost,
                style: isV4 ? nil : settings.style,
                use_speaker_boost: isV4 ? nil : settings.useSpeakerBoost,
                speed: isV4 ? nil : 1.0  // Playback speed stays client-side.
            ),
            previous_text: Self.trimmedPreviousContext(previousText)
        ))
    }

    public func synthesize(text: String, voiceID: String, settings: VoiceSettings) async throws -> SynthesisResult {
        try await synthesize(text: text, voiceID: voiceID, settings: settings, previousText: nil)
    }

    public func synthesize(
        text: String,
        voiceID: String,
        settings: VoiceSettings,
        previousText: String?
    ) async throws -> SynthesisResult {
        // Test seam for T-7 (fallback verification): behave exactly like a
        // quota-exhausted account without touching the network.
        if ProcessInfo.processInfo.environment["SR_SIMULATE_CLOUD_FAILURE"] == "1" {
            throw TTSError.http(status: 429, body: nil)
        }
        guard let key = KeychainStore.readAPIKey() else { throw TTSError.missingAPIKey }

        // Voice IDs come from settings / the voices API — encode rather than
        // trust, and fail cleanly instead of force-unwrapping.
        guard let encodedVoice = voiceID.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics),
              var components = URLComponents(
                string: "https://api.elevenlabs.io/v1/text-to-speech/\(encodedVoice)/stream")
        else {
            throw TTSError.http(status: 400, body: "invalid voice ID")
        }
        components.queryItems = [
            URLQueryItem(name: "output_format", value: audioQuality.outputFormat),
        ]
        guard let url = components.url else {
            throw TTSError.http(status: 400, body: "invalid voice ID")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try synthesisBody(
            text: text, settings: settings, previousText: previousText)

        // One fast retry on transient 502/503/504 or momentary socket drops
        // prevents a single edge blip from aborting a Cloud-mode read.
        var lastError: TTSError?
        for attempt in 0..<2 {
            if attempt > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    throw TTSError.cancelled
                }
            }
            do {
                return try await performSynthesizeRequest(request, charCount: text.count)
            } catch let error as TTSError where attempt == 0 && Self.isTransientRetryable(error) {
                lastError = error
                SRLog.event("elevenlabs.retry", ["reason": error.logCategory])
                continue
            } catch {
                throw error
            }
        }
        throw lastError ?? TTSError.network(underlying: "synthesis retry exhausted")
    }

    private static func isTransientRetryable(_ error: TTSError) -> Bool {
        switch error {
        case .http(let status, _):
            return status == 502 || status == 503 || status == 504
        case .network(let detail):
            return detail.contains("timed out")
                || detail.contains("connection was lost")
                || detail.contains("Could not connect")
        default:
            return false
        }
    }

    private func performSynthesizeRequest(
        _ request: URLRequest,
        charCount: Int
    ) async throws -> SynthesisResult {
        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch is CancellationError {
            throw TTSError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports task cancellation as URLError, not Swift
            // CancellationError — without this it's mislogged as a network
            // failure (and would count as a fallback trigger).
            throw TTSError.cancelled
        } catch {
            SRLog.error("elevenlabs.network", ["error": String(describing: type(of: error))])
            throw TTSError.network(underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TTSError.network(underlying: "non-HTTP response")
        }
        let latencyMS = Int(Date().timeIntervalSince(started) * 1000)

        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                KeychainStore.invalidateCache()
            }
            let body = String(data: data.prefix(300), encoding: .utf8)
            SRLog.error("elevenlabs.http", [
                "status": String(http.statusCode),
                "chars": String(charCount),
                "latency_ms": String(latencyMS),
            ])
            throw TTSError.http(status: http.statusCode, body: body)
        }

        let historyID = http.value(forHTTPHeaderField: "history-item-id")
        let billed = http.value(forHTTPHeaderField: "character-cost").flatMap(Int.init)
        guard AudioPayloadValidator.isMP3(data) else {
            SRLog.error("elevenlabs.invalid_audio", [
                "bytes": String(data.count),
                "content_type": http.value(forHTTPHeaderField: "Content-Type") ?? "missing",
                "history_id_present": historyID == nil ? "0" : "1",
            ])
            throw TTSError.invalidAudio(
                historyItemID: historyID,
                billedCharacters: billed)
        }

        SRLog.event("elevenlabs.ok", [
            "chars": String(charCount),
            "billed": String(billed ?? -1),
            "bytes": String(data.count),
            "latency_ms": String(latencyMS),
            "model": modelID,
            "format": audioQuality.outputFormat,
            "history_id_present": historyID == nil ? "0" : "1",
        ])
        return SynthesisResult(audio: data, remoteHistoryItemID: historyID, billedCharacters: billed)
    }

    // MARK: - Account info (C-1)

    public struct Subscription: Sendable {
        public let characterCount: Int
        public let characterLimit: Int
        public var remaining: Int { max(characterLimit - characterCount, 0) }
    }

    public func subscription() async throws -> Subscription {
        guard let key = KeychainStore.readAPIKey() else { throw TTSError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401 || status == 403 { KeychainStore.invalidateCache() }
            throw TTSError.http(status: status, body: nil)
        }
        struct Sub: Decodable {
            let character_count: Int
            let character_limit: Int
        }
        let sub = try JSONDecoder().decode(Sub.self, from: data)
        return Subscription(characterCount: sub.character_count, characterLimit: sub.character_limit)
    }

    /// Delete a generation from account history (P-6). Best-effort.
    /// Returns the HTTP status, or nil on network failure — callers need to
    /// distinguish 404 (item not materialized yet, or already gone) from
    /// transient failures.
    public func deleteHistoryItem(_ historyItemID: String) async -> Int? {
        guard let key = KeychainStore.readAPIKey() else { return nil }
        // History IDs come from a response header — encode, don't trust.
        guard let encodedID = historyItemID.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://api.elevenlabs.io/v1/history/\(encodedID)")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        guard let (_, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        SRLog.event("history.delete", ["status": String(http.statusCode)])
        return http.statusCode
    }
}
