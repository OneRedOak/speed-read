import CryptoKit
import Foundation

/// Content-addressed audio cache (P-10, F-9, C-4).
///
/// Key: SHA-256(normalized chunk text · provider · voice · model · voice
/// settings). Filenames are hashes — never text. Lives in
/// `~/Library/Application Support/sr/cache/`. LRU eviction over a size cap
/// (default 500 MB) plus a TTL (default 30 days). At-rest encryption is
/// FileVault's job (documented assumption).
public final class AudioCache: @unchecked Sendable {
    public static let shared = AudioCache()

    // Settings are read from pipeline tasks and the eviction queue while the
    // main thread writes them — lock rather than racing plain vars.
    private let stateLock = NSLock()
    private var _sizeCapBytes: Int
    private var _ttl: TimeInterval
    private var _enabled = true

    public var sizeCapBytes: Int {
        get { stateLock.withLock { _sizeCapBytes } }
        set { stateLock.withLock { _sizeCapBytes = newValue } }
    }
    public var ttl: TimeInterval {
        get { stateLock.withLock { _ttl } }
        set { stateLock.withLock { _ttl = newValue } }
    }
    /// "No-cache" toggle for sensitive sessions (P-10).
    public var enabled: Bool {
        get { stateLock.withLock { _enabled } }
        set { stateLock.withLock { _enabled = newValue } }
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "com.patrickellis.sr.cache", qos: .utility)
    private let evictionDebounce: TimeInterval
    /// Accessed only on `queue`.
    private var evictionWorkItem: DispatchWorkItem?
    private var evictionPasses = 0

    public init(directory: URL? = nil,
                sizeCapBytes: Int = 500_000_000,
                ttl: TimeInterval = 30 * 24 * 3600,
                evictionDebounce: TimeInterval = 0.25) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sr/cache", isDirectory: true)
        self._sizeCapBytes = sizeCapBytes
        self._ttl = ttl
        self.evictionDebounce = evictionDebounce
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: - Keying

    public static func key(text: String, provider: String, voiceID: String,
                           modelID: String, settings: VoiceSettings) -> String {
        var hasher = SHA256()
        // \u{1F} separators prevent field-boundary collisions.
        let material = [
            text, provider, voiceID, modelID,
            String(settings.stability), String(settings.similarityBoost),
            String(settings.style), String(settings.useSpeakerBoost),
        ].joined(separator: "\u{1F}")
        hasher.update(data: Data(material.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("mp3")
    }

    // MARK: - Read / write

    public func lookup(_ key: String) -> Data? {
        guard enabled else { return nil }
        let file = url(for: key)
        guard let data = try? Data(contentsOf: file) else {
            SRLog.event("cache.miss", [:])
            return nil
        }
        // Touch mtime for LRU.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: file.path)
        SRLog.event("cache.hit", ["bytes": String(data.count)])
        return data
    }

    public func store(_ key: String, data: Data) {
        guard enabled else { return }
        let file = url(for: key)
        queue.sync { [self] in
            // Re-check: "no-cache" flipped after enqueue must stay a hard
            // boundary — a queued write landing post-toggle would put
            // sensitive audio on disk.
            guard enabled else { return }
            try? data.write(to: file, options: .atomic)
            scheduleEviction()
        }
    }

    // MARK: - Maintenance

    /// One-click "Purge cache" (P-10).
    public func purge() {
        queue.async { [self] in
            let fm = FileManager.default
            for entry in (try? fm.contentsOfDirectory(at: directory,
                            includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: entry)
            }
            SRLog.event("cache.purged", [:])
        }
    }

    public func currentSizeBytes() -> Int {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
    }

    /// TTL sweep + LRU eviction down to the size cap. All maintenance runs
    /// on the cache queue so two evictions never race each other.
    public func evictIfNeeded() {
        queue.async { [self] in
            evictionWorkItem?.cancel()
            evictionWorkItem = nil
            performEviction()
        }
    }

    /// Test seam for proving that bursty stores coalesce maintenance work.
    var maintenancePassCount: Int {
        queue.sync { evictionPasses }
    }

    /// Called on `queue`. A synthesis burst can store several chunks in a few
    /// milliseconds; scanning the entire cache after each one turns writes
    /// into O(chunks × cache entries). One trailing sweep has the same size
    /// and TTL semantics with bounded delay.
    private func scheduleEviction() {
        guard evictionWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evictionWorkItem = nil
            self.performEviction()
        }
        evictionWorkItem = work
        queue.asyncAfter(deadline: .now() + evictionDebounce, execute: work)
    }

    private func performEviction() {
        evictionPasses += 1
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }

        var files: [(url: URL, size: Int, mtime: Date)] = entries.compactMap { entry in
            guard let values = try? entry.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let mtime = values.contentModificationDate else { return nil }
            return (entry, size, mtime)
        }

        // TTL first.
        let cutoff = Date().addingTimeInterval(-ttl)
        for file in files where file.mtime < cutoff {
            try? fm.removeItem(at: file.url)
        }
        files.removeAll { $0.mtime < cutoff }

        // Then LRU down to cap.
        var total = files.reduce(0) { $0 + $1.size }
        guard total > sizeCapBytes else { return }
        for file in files.sorted(by: { $0.mtime < $1.mtime }) {
            try? fm.removeItem(at: file.url)
            total -= file.size
            if total <= sizeCapBytes { break }
        }
        SRLog.event("cache.evicted", ["now_bytes": String(total)])
    }
}
