import Foundation
import SRCore

/// Bounded-concurrency chunk synthesis (F-5) with cache-first lookup (C-4),
/// exact-cost + history-ID reporting, and cloud→local fallback (F-3 Auto).
///
/// At most `maxInFlight` chunks synthesize concurrently; results are
/// delivered as they complete and the playback engine schedules in order.
/// Chunk 0 is requested first so playback starts fast.
///
/// Fallback (ported from speak.sh): when the primary provider fails with a
/// fallback-trigger error (429 / 5xx / network) and a fallback provider is
/// configured, the failed chunk is retried on the fallback and all
/// subsequent chunks go straight there. Fallback is one-way, cloud→local —
/// never local→cloud (that would violate P-8 routing guarantees).
final class SynthesisPipeline: @unchecked Sendable {
    static let maxInFlight = 3

    struct Route: Sendable {
        let provider: any TTSProvider
        let voiceID: String
        /// Modeled for cache keying; "" for providers without models.
        let modelID: String
    }

    struct Callbacks: Sendable {
        let deliver: @MainActor @Sendable (Int, Data) -> Void
        let billed: @Sendable (Int) -> Void
        let historyID: @Sendable (String) -> Void
        let fellBack: @MainActor @Sendable () -> Void
        let failed: @MainActor @Sendable (TTSError) -> Void
    }

    private var task: Task<Void, Never>?

    func run(
        chunks: [Chunk],
        primary: Route,
        fallback: Route?,
        settings: VoiceSettings,
        cache: AudioCache?,
        callbacks: Callbacks
    ) {
        cancel()
        let errorFlag = OnceFlag()
        let fallbackFlag = OnceFlag()
        let useFallback = AtomicBool()

        @Sendable func synthesize(_ chunk: Chunk) async throws -> Void {
            var route = useFallback.value ? (fallback ?? primary) : primary

            func cacheKey(_ r: Route) -> String {
                AudioCache.key(text: chunk.text, provider: r.provider.id,
                               voiceID: r.voiceID, modelID: r.modelID,
                               settings: settings)
            }

            // Cache first (C-4): zero credits, instant.
            if let cached = cache?.lookup(cacheKey(route)) {
                await callbacks.deliver(chunk.id, cached)
                return
            }

            var result: SynthesisResult
            do {
                result = try await route.provider.synthesize(
                    text: chunk.text, voiceID: route.voiceID, settings: settings)
            } catch let error as TTSError where error.isFallbackTrigger && fallback != nil && !route.provider.isLocal {
                // Flip to fallback for this and all subsequent chunks (T-7).
                useFallback.set(true)
                if fallbackFlag.trip() {
                    SRLog.event("pipeline.fallback", ["trigger": String(describing: error)])
                    await MainActor.run { callbacks.fellBack() }
                }
                route = fallback!
                if let cached = cache?.lookup(cacheKey(route)) {
                    await callbacks.deliver(chunk.id, cached)
                    return
                }
                result = try await route.provider.synthesize(
                    text: chunk.text, voiceID: route.voiceID, settings: settings)
            }

            if let billed = result.billedCharacters { callbacks.billed(billed) }
            if let historyID = result.remoteHistoryItemID { callbacks.historyID(historyID) }
            cache?.store(cacheKey(route), data: result.audio)
            guard !Task.isCancelled else { return }
            await callbacks.deliver(chunk.id, result.audio)
        }

        task = Task {
            await withTaskGroup(of: Void.self) { group in
                var iterator = chunks.makeIterator()
                var active = 0

                func spawnNext() -> Bool {
                    guard let chunk = iterator.next() else { return false }
                    active += 1
                    group.addTask {
                        do {
                            try await synthesize(chunk)
                        } catch let error as TTSError {
                            guard !Task.isCancelled, error != .cancelled else { return }
                            if errorFlag.trip() {
                                await MainActor.run { callbacks.failed(error) }
                            }
                        } catch {
                            // Non-TTSError (URLSession cancellation etc.) — ignore.
                        }
                    }
                    return true
                }

                for _ in 0..<Self.maxInFlight {
                    if !spawnNext() { break }
                }
                while active > 0 {
                    await group.next()
                    active -= 1
                    if Task.isCancelled { group.cancelAll(); break }
                    _ = spawnNext()
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Thread-safe once-only latch for first-error reporting.
private final class OnceFlag: @unchecked Sendable {
    private var tripped = false
    private let lock = NSLock()

    /// Returns true exactly once.
    func trip() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}

private final class AtomicBool: @unchecked Sendable {
    private var stored = false
    private let lock = NSLock()

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: Bool) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }
}

extension TTSError: Equatable {
    public static func == (lhs: TTSError, rhs: TTSError) -> Bool {
        switch (lhs, rhs) {
        case (.missingAPIKey, .missingAPIKey), (.cancelled, .cancelled):
            return true
        case (.http(let a, _), .http(let b, _)):
            return a == b
        case (.network(let a), .network(let b)):
            return a == b
        default:
            return false
        }
    }
}
