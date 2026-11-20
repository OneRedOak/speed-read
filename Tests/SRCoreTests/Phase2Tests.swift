import Foundation
import Testing
@testable import SRCore

private final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

@Suite struct RoutingPolicyTests {
    @Test func exactMatchWins() {
        var policy = RoutingPolicy(rules: ["com.apple.mail": .forceLocal])
        #expect(policy.action(for: "com.apple.mail") == .forceLocal)
        #expect(policy.action(for: "com.apple.notes") == .default)
        policy = RoutingPolicy(rules: [:])
        #expect(policy.action(for: "com.apple.mail") == .default)
    }

    @Test func wildcardPrefix() {
        let policy = RoutingPolicy(rules: ["com.1password.*": .block])
        #expect(policy.action(for: "com.1password.1password") == .block)
        #expect(policy.action(for: "com.1password.op-helper") == .block)
        #expect(policy.action(for: "com.1passwordish.other") == .default)
    }

    @Test func exactBeatsWildcard() {
        let policy = RoutingPolicy(rules: [
            "com.example.*": .block,
            "com.example.safe": .default,
        ])
        #expect(policy.action(for: "com.example.safe") == .default)
        #expect(policy.action(for: "com.example.danger") == .block)
    }

    @Test func shippedDefaultsBlockPasswordManagers() {
        let policy = RoutingPolicy(rules: RoutingPolicy.shippedDefaults)
        #expect(policy.action(for: "com.1password.1password8") == .block)
        #expect(policy.action(for: "com.apple.keychainaccess") == .block)
        #expect(policy.action(for: "com.apple.Safari") == .default)
        #expect(policy.action(for: nil) == .default)
    }
}

@Suite struct BackendRoutingTests {
    @Test func localModeIsAlwaysLocal() {
        #expect(BackendRouting.plan(
            mode: .local, forceLocal: false,
            localAvailable: true, hasCloudCredential: true) == .localOnly)
        #expect(BackendRouting.plan(
            mode: .local, forceLocal: false,
            localAvailable: false, hasCloudCredential: true) == .localUnavailable)
    }

    @Test func cloudModeNeverFallsBackLocally() {
        #expect(BackendRouting.plan(
            mode: .cloud, forceLocal: false,
            localAvailable: true, hasCloudCredential: true) == .cloudOnly)
    }

    @Test func autoUsesAvailableCredentialsAndFallback() {
        #expect(BackendRouting.plan(
            mode: .auto, forceLocal: false,
            localAvailable: true, hasCloudCredential: true) == .cloudWithLocalFallback)
        #expect(BackendRouting.plan(
            mode: .auto, forceLocal: false,
            localAvailable: true, hasCloudCredential: false) == .localOnly)
        #expect(BackendRouting.plan(
            mode: .auto, forceLocal: false,
            localAvailable: false, hasCloudCredential: false) == .cloudOnly)
    }

    @Test func forceLocalCanOnlyTightenPrivacy() {
        #expect(BackendRouting.plan(
            mode: .cloud, forceLocal: true,
            localAvailable: true, hasCloudCredential: true) == .localOnly)
    }
}

@Suite struct AudioPayloadValidatorTests {
    @Test func recognizesMP3Headers() {
        #expect(AudioPayloadValidator.isMP3(Data([0x49, 0x44, 0x33, 0x04])))
        #expect(AudioPayloadValidator.isMP3(Data([0xFF, 0xFB, 0x90, 0x64])))
        #expect(!AudioPayloadValidator.isMP3(Data("not audio".utf8)))
    }

    @Test func recognizesWAVContainer() {
        #expect(AudioPayloadValidator.isWAV(Data("RIFF1234WAVEdata".utf8)))
        #expect(!AudioPayloadValidator.isWAV(Data("RIFF1234NOPEdata".utf8)))
    }

    @Test func invalidCloudAudioCanFallbackWithoutLosingMetadata() {
        let error = TTSError.invalidAudio(
            historyItemID: "history-1", billedCharacters: 42)
        #expect(error.isFallbackTrigger)
    }
}

@Suite struct HistoryJanitorTests {
    @Test func pendingSnapshotIncludesActiveDeletion() async throws {
        let janitor = HistoryJanitor(initialDelay: 0) { _ in
            try? await Task.sleep(for: .milliseconds(150))
            return 200
        }
        await janitor.enqueue("history-1")
        try await Task.sleep(for: .milliseconds(20))
        #expect(await janitor.pendingIDs == ["history-1"])
        #expect(await janitor.waitUntilDrained(timeout: 1))
    }

    @Test func retryingItemDoesNotHeadOfLineBlockReadyItems() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            var deletedOrder: [String] = []
            var attempts: [String: Int] = [:]
            func handle(_ id: String) -> Int {
                lock.withLock {
                    let count = (attempts[id] ?? 0) + 1
                    attempts[id] = count
                    if id == "slow-404" && count == 1 { return 404 }
                    deletedOrder.append(id)
                    return 200
                }
            }
            func snapshot() -> [String] { lock.withLock { deletedOrder } }
        }
        let recorder = Recorder()
        let janitor = HistoryJanitor(initialDelay: 0, retryDelays: [0.35]) { id in
            recorder.handle(id)
        }
        await janitor.enqueue("slow-404")
        await janitor.enqueue("ready-2")
        #expect(await janitor.waitUntilDrained(timeout: 2))
        // `ready-2` must finish BEFORE `slow-404`'s 350 ms retry fires.
        #expect(recorder.snapshot() == ["ready-2", "slow-404"])
    }
}

@Suite struct PlaybackCompletionPolicyTests {
    @Test func waitsForDecodeRenderAndScheduledWork() {
        #expect(!PlaybackCompletionPolicy.canFinish(
            totalSentences: 2, appendedSentences: 2,
            pendingDecodes: 0, pendingRenders: 1, scheduledBuffers: 0))
        #expect(!PlaybackCompletionPolicy.canFinish(
            totalSentences: 2, appendedSentences: 2,
            pendingDecodes: 1, pendingRenders: 0, scheduledBuffers: 0))
        #expect(!PlaybackCompletionPolicy.canFinish(
            totalSentences: 2, appendedSentences: 2,
            pendingDecodes: 0, pendingRenders: 0, scheduledBuffers: 1))
        #expect(PlaybackCompletionPolicy.canFinish(
            totalSentences: 2, appendedSentences: 2,
            pendingDecodes: 0, pendingRenders: 0, scheduledBuffers: 0))
    }
}

@Suite struct CostLedgerTests {
    private func freshLedger() -> CostLedger {
        let defaults = UserDefaults(suiteName: "sr-tests-\(UUID().uuidString)")!
        return CostLedger(defaults: defaults)
    }

    @Test func recordsAndAccumulates() {
        let ledger = freshLedger()
        #expect(ledger.spentToday == 0)
        ledger.record(billedCharacters: 100)
        ledger.record(billedCharacters: 50)
        #expect(ledger.spentToday == 150)
    }

    @Test func verdictThresholds() {
        let ledger = freshLedger()
        ledger.dailyBudget = 1000
        #expect(ledger.verdict() == .ok)
        ledger.record(billedCharacters: 799)
        #expect(ledger.verdict() == .ok)
        ledger.record(billedCharacters: 1)   // 800 = 80%
        #expect(ledger.verdict() == .warning(spent: 800, budget: 1000))
        ledger.record(billedCharacters: 200) // 1000 = 100%
        #expect(ledger.verdict() == .exceeded(spent: 1000, budget: 1000))
    }

    @Test func overrideSuspendsEnforcement() {
        let ledger = freshLedger()
        ledger.dailyBudget = 10
        ledger.record(billedCharacters: 50)
        #expect(ledger.verdict() == .exceeded(spent: 50, budget: 10))
        ledger.overriddenToday = true
        #expect(ledger.verdict() == .ok)
    }

    @Test func concurrentRecordingIsThreadSafeAndIgnoresNegatives() async {
        let ledger = freshLedger()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    ledger.record(billedCharacters: 10)
                    ledger.record(billedCharacters: -50)
                    _ = ledger.spentToday
                }
            }
        }
        #expect(ledger.spentToday == 200)
    }
}

@Suite final class AudioCacheTests {
    private var tempDirs: [URL] = []

    deinit {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func freshCache(evictionDebounce: TimeInterval = 0.25) -> AudioCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-cache-test-\(UUID().uuidString)")
        tempDirs.append(dir)
        return AudioCache(directory: dir, sizeCapBytes: 1000, ttl: 3600,
                          evictionDebounce: evictionDebounce)
    }

    @Test func keyIsStableAndCollisionResistant() {
        let a = AudioCache.key(text: "hello", provider: "elevenlabs",
                               voiceID: "v1", modelID: "m1", settings: VoiceSettings())
        let b = AudioCache.key(text: "hello", provider: "elevenlabs",
                               voiceID: "v1", modelID: "m1", settings: VoiceSettings())
        let c = AudioCache.key(text: "hello", provider: "elevenlabs",
                               voiceID: "v2", modelID: "m1", settings: VoiceSettings())
        // Field-boundary collision: text "x·v" vs voice must not collide.
        let d = AudioCache.key(text: "hellov1", provider: "elevenlabs",
                               voiceID: "", modelID: "m1", settings: VoiceSettings())
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a.count == 64)
    }

    @Test func storeIsImmediatelyVisible() {
        let cache = freshCache()
        let key = AudioCache.key(text: "t", provider: "p", voiceID: "v",
                                 modelID: "m", settings: VoiceSettings())
        #expect(cache.lookup(key) == nil)
        cache.store(key, data: Data([1, 2, 3]))
        #expect(cache.lookup(key) == Data([1, 2, 3]))
    }

    @Test func roundTripAndPurge() async throws {
        let cache = freshCache()
        let key = AudioCache.key(text: "t", provider: "p", voiceID: "v",
                                 modelID: "m", settings: VoiceSettings())
        cache.store(key, data: Data([1, 2, 3]))
        cache.purge()
        // Pending in-memory writes must vanish immediately on purge, before
        // even waiting for the async disk sweep.
        #expect(cache.lookup(key) == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(cache.lookup(key) == nil)
    }

    @Test func optionalContextAndFormatPreserveDefaultKeyCompatibility() {
        let base = AudioCache.key(text: "hello", provider: "elevenlabs",
                                  voiceID: "v1", modelID: "m1", settings: VoiceSettings())
        let same = AudioCache.key(text: "hello", provider: "elevenlabs",
                                  voiceID: "v1", modelID: "m1", settings: VoiceSettings(),
                                  previousContext: "", outputFormat: nil)
        let withCtx = AudioCache.key(text: "hello", provider: "elevenlabs",
                                     voiceID: "v1", modelID: "m1", settings: VoiceSettings(),
                                     previousContext: "Prior sentence.", outputFormat: nil)
        let withFmt = AudioCache.key(text: "hello", provider: "elevenlabs",
                                     voiceID: "v1", modelID: "m1", settings: VoiceSettings(),
                                     previousContext: "", outputFormat: "mp3_44100_64")
        #expect(base == same)
        #expect(base != withCtx)
        #expect(base != withFmt)
        #expect(withCtx != withFmt)
    }

    @Test func disabledCacheStoresNothing() async throws {
        let cache = freshCache()
        cache.enabled = false
        let key = AudioCache.key(text: "t2", provider: "p", voiceID: "v",
                                 modelID: "m", settings: VoiceSettings())
        cache.store(key, data: Data([9]))
        try await Task.sleep(for: .milliseconds(200))
        cache.enabled = true
        #expect(cache.lookup(key) == nil)
    }

    @Test func disablingCacheRetractsAnAlreadyStartedWrite() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-cache-test-\(UUID().uuidString)")
        tempDirs.append(dir)
        let writeStarted = LockedTestFlag()
        let allowWrite = DispatchSemaphore(value: 0)
        let cache = AudioCache(
            directory: dir,
            sizeCapBytes: 1000,
            ttl: 3600,
            evictionDebounce: 0.25,
            beforeDiskWrite: {
                writeStarted.set()
                allowWrite.wait()
            })
        let key = AudioCache.key(text: "race", provider: "p", voiceID: "v",
                                 modelID: "m", settings: VoiceSettings())

        cache.store(key, data: Data([7, 8, 9]))
        while !writeStarted.value { await Task.yield() }
        let disable = Task.detached { cache.enabled = false }
        while cache.enabled { await Task.yield() }
        allowWrite.signal()
        await disable.value

        cache.enabled = true
        #expect(cache.lookup(key) == nil)
    }

    @Test func burstStoresCoalesceEviction() async throws {
        let cache = freshCache(evictionDebounce: 0.02)
        for index in 0..<20 {
            cache.store("key-\(index)", data: Data([UInt8(index)]))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(cache.maintenancePassCount == 1)
    }
}
