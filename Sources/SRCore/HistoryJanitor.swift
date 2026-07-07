import Foundation

/// Deletes each ElevenLabs generation from account history right after
/// synthesis (P-6). Best-effort by design: ElevenLabs states backups purge
/// within ~30 days and moderation/debug logs may persist; true zero
/// retention (`enable_logging=false`) is enterprise-gated.
///
/// Mechanism (live-verified 2026-07-06): the streaming TTS response carries
/// a `history-item-id` header; `DELETE /v1/history/{id}` returns 200.
public actor HistoryJanitor {
    public enum LastStatus: Sendable, Equatable {
        case idle
        case ok(count: Int, at: Date)
        case failed(count: Int, at: Date)
    }

    private let provider = ElevenLabsProvider()
    private var pending: [String] = []
    private var draining = false
    private var deletedTotal = 0
    private var failedTotal = 0
    public private(set) var lastStatus: LastStatus = .idle

    public init() {}

    /// Queue a history item for deletion and drain asynchronously.
    public func enqueue(_ historyItemID: String) {
        pending.append(historyItemID)
        drain()
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        Task {
            await self.processQueue()
        }
    }

    private func processQueue() async {
        while let id = pending.first {
            pending.removeFirst()
            var ok = await provider.deleteHistoryItem(id)
            if !ok {
                // One retry after a short pause (transient network hiccup).
                try? await Task.sleep(for: .seconds(2))
                ok = await provider.deleteHistoryItem(id)
            }
            if ok {
                deletedTotal += 1
                lastStatus = .ok(count: deletedTotal, at: Date())
            } else {
                failedTotal += 1
                lastStatus = .failed(count: failedTotal, at: Date())
                SRLog.error("history.delete_failed", [:])
            }
        }
        draining = false
    }

    /// Human-readable status for the menu ("History: 12 deleted").
    public var statusLine: String {
        switch lastStatus {
        case .idle:
            return "History cleanup: idle"
        case .ok(let count, _):
            return "History: \(count) generation\(count == 1 ? "" : "s") auto-deleted"
        case .failed(let count, _):
            return "History cleanup: \(count) deletion\(count == 1 ? "" : "s") failed"
        }
    }
}
