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

    private struct PendingDelete {
        let id: String
        var attempts: Int
        var notBefore: Date
    }

    /// Deleting immediately after synthesis races ElevenLabs' own history
    /// materialization: too-early deletes 404 and the item appears LATER,
    /// lingering forever. Wait before the first attempt, and re-try 404s on
    /// a widening schedule before trusting that the item is really gone.
    static let initialDelay: TimeInterval = 2.5
    static let retryDelays: [TimeInterval] = [6, 20]

    private let provider = ElevenLabsProvider()
    private var pending: [PendingDelete] = []
    private var draining = false
    private var deletedTotal = 0
    private var failedTotal = 0
    public private(set) var lastStatus: LastStatus = .idle

    public init() {}

    /// Queue a history item for deletion and drain asynchronously.
    public func enqueue(_ historyItemID: String) {
        pending.append(PendingDelete(
            id: historyItemID,
            attempts: 0,
            notBefore: Date().addingTimeInterval(Self.initialDelay)))
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
        while !pending.isEmpty {
            // FIFO, but never before an item's notBefore time.
            var item = pending.removeFirst()
            let wait = item.notBefore.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }

            switch await provider.deleteHistoryItem(item.id) {
            case 200:
                deletedTotal += 1
                lastStatus = .ok(count: deletedTotal, at: Date())
            case 404 where item.attempts < Self.retryDelays.count:
                item.notBefore = Date().addingTimeInterval(Self.retryDelays[item.attempts])
                item.attempts += 1
                pending.append(item)
            case 404:
                // Retried past the materialization window — genuinely gone
                // (deleted by an earlier request, or never persisted).
                deletedTotal += 1
                lastStatus = .ok(count: deletedTotal, at: Date())
            default:
                // Transient (network / 5xx): one more try, then give up.
                if item.attempts < Self.retryDelays.count {
                    item.notBefore = Date().addingTimeInterval(Self.retryDelays[item.attempts])
                    item.attempts += 1
                    pending.append(item)
                } else {
                    failedTotal += 1
                    lastStatus = .failed(count: failedTotal, at: Date())
                    SRLog.error("history.delete_failed", [:])
                }
            }
        }
        draining = false
    }

    /// Await the queue emptying (deletes + retry schedule). Returns true
    /// when everything was processed, false on timeout with work pending.
    /// The 404-retry ladder spans ~30 s worst case — callers that must not
    /// exit with deletions pending (the CLI) should allow at least that.
    public func waitUntilDrained(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while (draining || !pending.isEmpty) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return pending.isEmpty && !draining
    }

    /// IDs still awaiting deletion — persisted across app quits so pending
    /// deletes survive (IDs are opaque provider tokens, content-free).
    public var pendingIDs: [String] {
        pending.map(\.id)
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
