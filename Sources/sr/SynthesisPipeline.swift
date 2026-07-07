import Foundation
import SRCore

/// Bounded-concurrency chunk synthesis (F-5).
///
/// Synthesizes sentence chunks with at most `maxInFlight` concurrent
/// requests, delivering results (in whatever order they complete) to the
/// playback engine, which schedules them in order. Chunk 0 is requested
/// first so playback starts as soon as the first sentence is ready.
final class SynthesisPipeline: @unchecked Sendable {
    static let maxInFlight = 3

    private var task: Task<Void, Never>?

    /// History item IDs collected this session (feeds P-6 janitor, Phase 2).
    private(set) var historyItemIDs: [String] = []
    private let historyLock = NSLock()

    func run(
        chunks: [Chunk],
        provider: some TTSProvider,
        voiceID: String,
        settings: VoiceSettings,
        deliver: @escaping @MainActor (Int, Data) -> Void,
        failed: @escaping @MainActor (TTSError) -> Void
    ) {
        cancel()
        let errorFlag = OnceFlag()
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = chunks.makeIterator()
                var active = 0

                func spawnNext() -> Bool {
                    guard let chunk = iterator.next() else { return false }
                    active += 1
                    group.addTask {
                        do {
                            let result = try await provider.synthesize(
                                text: chunk.text, voiceID: voiceID, settings: settings)
                            if let historyID = result.remoteHistoryItemID {
                                self?.recordHistoryID(historyID)
                            }
                            guard !Task.isCancelled else { return }
                            await deliver(chunk.id, result.audio)
                        } catch let error as TTSError {
                            guard !Task.isCancelled, error != .cancelled else { return }
                            if errorFlag.trip() {
                                await MainActor.run { failed(error) }
                            }
                        } catch {
                            // Non-TTSError (URLSession cancellation etc.) — ignore.
                        }
                    }
                    return true
                }

                // Prime the window.
                for _ in 0..<Self.maxInFlight {
                    if !spawnNext() { break }
                }
                // Refill as requests complete.
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

    private func recordHistoryID(_ id: String) {
        historyLock.lock()
        historyItemIDs.append(id)
        historyLock.unlock()
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
