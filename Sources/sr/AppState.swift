import AppKit
import Combine
import Foundation
@preconcurrency import KeyboardShortcuts
import SRCore
import SwiftUI

@MainActor
extension KeyboardShortcuts.Name {
    /// ⌥⇧/ — speak selection, or stop if speaking (F-1, F-2).
    static let speakOrStop = Self("speakOrStop",
        default: .init(.slash, modifiers: [.option, .shift]))
    /// ⌥⇧. — pause/resume (F-2).
    static let pauseResume = Self("pauseResume",
        default: .init(.period, modifiers: [.option, .shift]))
}

/// Central controller: hotkeys → routing → capture → normalize → chunk →
/// synthesize (cache-first, budgeted) → play. Owns all mutable app state.
@MainActor
final class AppState: ObservableObject {
    enum ActiveBackend: Equatable {
        case cloud
        case local

        var label: String {
            switch self {
            case .cloud: return "Cloud"
            case .local: return "Local"
            }
        }
    }

    enum ErrorAction: Equatable {
        case openSettings
        case installOffline
    }

    private let servicesEnabled: Bool
    let settings: SettingsStore
    let playback: PlaybackEngine
    let ledger: CostLedger
    private let pipeline = SynthesisPipeline()
    private let janitor = HistoryJanitor()
    private var routing: RoutingPolicy
    private var routingModifiedAt: Date?

    /// Transient info status (clears automatically after a few seconds).
    @Published var statusMessage: String?
    /// Actionable error banner (stays visible until dismissed or next read).
    @Published var lastError: String?
    @Published var errorAction: ErrorAction?
    @Published var activeBackend: ActiveBackend?

    @Published var creditsRemaining: Int?
    @Published var creditsLimit: Int?
    /// Account voice list (F-10); presets until the first fetch lands.
    @Published var availableVoices: [Voice] = ElevenLabsProvider.presetVoices
    private var voicesFetchedAt: Date?
    @Published var historyStatus: String = ""
    @Published var kokoroInstallStatus: String?
    @Published var kokoroInstalled: Bool
    @Published var kokoroNeedsUpdate: Bool
    @Published var kokoroDaemonRunning = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    // Reactive mirrors of CostLedger + Cache metrics so SwiftUI updates immediately.
    @Published var spentToday: Int
    @Published var budgetOverriddenToday: Bool
    @Published var dailyBudget: Int {
        didSet {
            let clamped = max(0, dailyBudget)
            if clamped != dailyBudget { dailyBudget = clamped; return }
            ledger.dailyBudget = clamped
        }
    }
    @Published var largeReadThreshold: Int {
        didSet {
            let clamped = max(0, largeReadThreshold)
            if clamped != largeReadThreshold { largeReadThreshold = clamped; return }
            ledger.largeReadThreshold = clamped
        }
    }
    @Published var cacheSizeBytes: Int = 0

    @Published var playbackRate: Double {
        didSet {
            settings.playbackRate = playbackRate
            playback.rate = playbackRate
        }
    }
    @Published var sentencePauseMS: Int {
        didSet {
            let clamped = min(max(sentencePauseMS, 0), 1500)
            if clamped != sentencePauseMS { sentencePauseMS = clamped; return }
            settings.sentencePauseMS = clamped
            playback.sentencePauseMS = clamped
        }
    }
    @Published var voiceID: String {
        didSet { settings.voiceID = voiceID }
    }
    @Published var localVoiceID: String {
        didSet { settings.localVoiceID = localVoiceID }
    }
    @Published var modelID: String {
        didSet { settings.modelID = modelID }
    }
    @Published var audioQuality: ElevenLabsProvider.AudioQuality {
        didSet { settings.audioQuality = audioQuality }
    }
    @Published var voiceStability: Double {
        didSet {
            var vs = settings.voiceSettings
            vs.stability = voiceStability
            settings.voiceSettings = vs
        }
    }
    @Published var voiceSimilarityBoost: Double {
        didSet {
            var vs = settings.voiceSettings
            vs.similarityBoost = voiceSimilarityBoost
            settings.voiceSettings = vs
        }
    }

    /// Backend mode; `.local` is the Local-Only master switch (P-8).
    @Published var backendMode: SettingsStore.BackendMode {
        didSet {
            settings.backendMode = backendMode
            // Local-Only is a live privacy boundary, not a preference for the
            // next read. Stop a cloud-backed session before more chunks upload.
            if backendMode == .local, oldValue != .local, activeUsesCloud {
                stop()
                flashStatus("Cloud read stopped — Local-Only is active")
            }
            if servicesEnabled, backendMode != .cloud, oldValue == .cloud {
                prewarmKokoroIfNeeded()
            }
        }
    }
    @Published var autoDeleteHistory: Bool {
        didSet { settings.autoDeleteHistory = autoDeleteHistory }
    }
    @Published var cacheEnabled: Bool {
        didSet {
            settings.cacheEnabled = cacheEnabled
            if servicesEnabled {
                AudioCache.shared.enabled = cacheEnabled
            }
        }
    }

    private var statusClearTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var accessibilityPollTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// Serializes selection captures: two concurrent ⌘C fallbacks snapshot/
    /// restore each other's transient pasteboard state and can permanently
    /// replace the user's clipboard with the selection (P-3 violation).
    private var captureInFlight = false
    /// Bumped per speak(); stale pipeline deliveries (a chunk that slipped
    /// past cancellation) are dropped instead of feeding into the new session.
    private var speakGeneration = 0
    private var preparationGeneration = 0
    private var activeUsesCloud = false

    init(
        store: SettingsStore = SettingsStore(),
        ledger: CostLedger = CostLedger(),
        startServices: Bool = true
    ) {
        settings = store
        self.ledger = ledger
        servicesEnabled = startServices
        routing = startServices ? RoutingPolicy.load() : RoutingPolicy(rules: RoutingPolicy.shippedDefaults)
        routingModifiedAt = startServices ? Self.fileModifiedDate(RoutingPolicy.fileURL) : nil

        playback = PlaybackEngine(rate: store.playbackRate,
                                  sentencePauseMS: store.sentencePauseMS)
        playbackRate = store.playbackRate
        sentencePauseMS = store.sentencePauseMS
        voiceID = store.voiceID
        localVoiceID = store.localVoiceID
        modelID = store.modelID
        audioQuality = store.audioQuality
        let vs = store.voiceSettings
        voiceStability = vs.stability
        voiceSimilarityBoost = vs.similarityBoost
        backendMode = store.backendMode
        autoDeleteHistory = store.autoDeleteHistory
        cacheEnabled = store.cacheEnabled

        dailyBudget = ledger.dailyBudget
        largeReadThreshold = ledger.largeReadThreshold
        spentToday = ledger.spentToday
        budgetOverriddenToday = ledger.overriddenToday

        kokoroInstalled = startServices ? KokoroRuntime.shared.isInstalled : false
        kokoroNeedsUpdate = startServices ? KokoroRuntime.shared.installer.needsUpdate : false

        playback.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        guard startServices else { return }

        AudioCache.shared.enabled = store.cacheEnabled

        KeyboardShortcuts.onKeyDown(for: .speakOrStop) { [weak self] in
            Task { @MainActor in self?.speakOrStop() }
        }
        KeyboardShortcuts.onKeyDown(for: .pauseResume) { [weak self] in
            Task { @MainActor in self?.playback.togglePauseResume() }
        }

        if !accessibilityGranted {
            promptForAccessibility()
        }
        refreshCredits()
        refreshVoices()
        refreshCacheSize()
        refreshKokoroDaemonStatus()

        // Resume history deletions that were pending when the app last quit.
        if let ids = UserDefaults.standard.stringArray(forKey: Self.pendingDeletesKey),
           !ids.isEmpty {
            let janitor = janitor
            Task {
                for id in ids { await janitor.enqueue(id) }
                UserDefaults.standard.removeObject(forKey: Self.pendingDeletesKey)
            }
        }

        // Startup cache maintenance (TTL sweep + LRU).
        Task.detached(priority: .utility) {
            AudioCache.shared.evictIfNeeded()
        }

        // Keep the installed daemon script current with the bundled one —
        // daemon fixes in app updates would otherwise never reach installs.
        if KokoroRuntime.shared.isInstalled, let source = daemonScriptSource() {
            KokoroRuntime.shared.installer.syncDaemonScript(from: source)
        }

        prewarmKokoroIfNeeded()
    }

    private nonisolated static let pendingDeletesKey = "pendingHistoryDeletes"

    private static func fileModifiedDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Reload `rules.json` on demand when edited on disk so users don't need
    /// to relaunch sr after adding per-app routing rules.
    private func currentRoutingPolicy() -> RoutingPolicy {
        guard servicesEnabled else { return routing }
        let mod = Self.fileModifiedDate(RoutingPolicy.fileURL)
        if mod != routingModifiedAt {
            routing = RoutingPolicy.load()
            routingModifiedAt = mod
        }
        return routing
    }

    /// Pre-warm the local daemon when it can be needed (Auto fallback or
    /// Local mode), using the user's selected voice so the right language
    /// pipeline + G2P model is hot before the first hotkey press.
    func prewarmKokoroIfNeeded() {
        guard servicesEnabled, backendMode != .cloud, KokoroRuntime.shared.isInstalled else { return }
        let voice = localVoiceID
        Task(priority: .utility) { [weak self] in
            try? await KokoroRuntime.shared.supervisor.ensureRunning(warmupVoice: voice)
            self?.refreshKokoroDaemonStatus()
        }
    }

    func shutdown() async {
        stop()
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
        installTask?.cancel()
        await installTask?.value
        installTask = nil
        // Persist not-yet-completed history deletions across quits (IDs are
        // opaque provider tokens — content-free). Re-enqueued at next launch.
        let ids = await janitor.pendingIDs
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingDeletesKey)
        } else {
            UserDefaults.standard.set(ids, forKey: Self.pendingDeletesKey)
        }
        UserDefaults.standard.synchronize()
        await KokoroRuntime.shared.supervisor.stop()
    }

    // MARK: - Speed & error helpers

    /// Set playback speed immediately (used by preset chips — no slider debounce).
    func setPlaybackRateImmediate(_ newRate: Double) {
        let clamped = min(max(newRate, 0.5), 3.0)
        playbackRate = clamped
        playback.setRate(clamped, immediate: true)
    }

    func dismissError() {
        lastError = nil
        errorAction = nil
    }

    private func reportError(_ message: String, action: ErrorAction? = nil) {
        lastError = message
        errorAction = action
        statusMessage = nil
        statusClearTask?.cancel()
    }

    // MARK: - Primary flows

    /// Primary hotkey: always speak the current selection. If something is
    /// already playing, the new read replaces it; an empty selection leaves
    /// current playback untouched. (Q-5 revisited by user request — stopping
    /// is the pause hotkey's and the menu's job.)
    func speakOrStop() {
        let policy = currentRoutingPolicy()
        // Routing is decided on the app that is frontmost at hotkey time (P-8).
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let action = policy.action(for: bundleID)
        if action == .block {
            NSSound.beep()
            flashStatus("Speaking blocked for this app")
            SRLog.event("routing.blocked", [:])
            return
        }
        // Capture must run off the main thread: the ⌘C fallback sleeps
        // while polling the pasteboard.
        guard !captureInFlight else { return }
        captureInFlight = true
        let preparation = preparationGeneration
        Task.detached { [self] in
            let result = SelectionCapture.capture()
            await MainActor.run {
                captureInFlight = false
                // Let capture restore the clipboard, but never let a late
                // completion undo Stop or replace a newer read.
                guard preparationGeneration == preparation else { return }
                handleCapture(result, fallbackRoutingAction: action, fromClipboard: false)
            }
        }
    }

    func speakClipboard() {
        let policy = currentRoutingPolicy()
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let action = policy.action(for: bundleID)
        if action == .block {
            NSSound.beep()
            flashStatus("Speaking blocked for this app")
            SRLog.event("routing.blocked", ["source": "clipboard"])
            return
        }
        // Inspect clipboard BEFORE stopping active playback so an empty or
        // concealed clipboard never kills a read already in progress.
        handleCapture(SelectionCapture.clipboardText(), fallbackRoutingAction: action, fromClipboard: true)
    }

    func stop() {
        // Invalidate callbacks already queued on the main actor as well as
        // cancelling their tasks. They must not change a replacement session.
        speakGeneration += 1
        preparationGeneration += 1
        preparationTask?.cancel()
        preparationTask = nil
        pipeline.cancel()
        playback.stop()
        activeUsesCloud = false
        activeBackend = nil
    }

    private func handleCapture(_ result: SelectionCapture.CaptureResult,
                               fallbackRoutingAction: RoutingPolicy.Action,
                               fromClipboard: Bool) {
        switch result {
        case .accessibilityDenied:
            accessibilityGranted = false
            promptForAccessibility()
        case .concealed:
            NSSound.beep()
            flashStatus("Concealed content skipped")
        case .empty:
            // Leave any current playback running — a missed selection or
            // non-text clipboard shouldn't kill the read in progress.
            NSSound.beep()
            flashStatus(fromClipboard ? "Clipboard has no readable text" : "No selection found")
        case .text(let raw, let method, let sourceBundleID):
            let policy = currentRoutingPolicy()
            // Re-resolve against the element that actually supplied the text.
            // Focus can change while the detached AX/clipboard capture runs.
            let routingAction = sourceBundleID.map { policy.action(for: $0) }
                ?? fallbackRoutingAction
            if routingAction == .block {
                NSSound.beep()
                flashStatus("Speaking blocked for this app")
                SRLog.event("routing.blocked", ["source": method.rawValue])
                return
            }
            dismissError()
            speak(raw, captureMethod: method, routingAction: routingAction)
        }
    }

    /// Resolve primary/fallback providers from backend mode + routing (F-3, P-8).
    private func resolveRoutes(routingAction: RoutingPolicy.Action)
        -> (primary: SynthesisPipeline.Route, fallback: SynthesisPipeline.Route?, isLocal: Bool)? {
        let wantsLocal = backendMode == .local || routingAction == .forceLocal
        let kokoroReady = KokoroRuntime.shared.isInstalled

        let localRoute = SynthesisPipeline.Route(
            provider: KokoroProvider(), voiceID: localVoiceID, modelID: KokoroProvider.cacheModelID)
        let cloudRoute = SynthesisPipeline.Route(
            provider: ElevenLabsProvider(modelID: modelID, audioQuality: audioQuality),
            voiceID: voiceID, modelID: modelID)

        let plan = BackendRouting.plan(
            mode: backendMode,
            forceLocal: wantsLocal,
            localAvailable: kokoroReady,
            hasCloudCredential: KeychainStore.readAPIKey() != nil)

        switch plan {
        case .localUnavailable:
            reportError(
                kokoroNeedsUpdate
                    ? "Offline voices need an update before local reading."
                    : "Offline voices aren't installed yet.",
                action: .installOffline)
            return nil
        case .localOnly:
            return (localRoute, nil, true)
        case .cloudOnly:
            return (cloudRoute, nil, false)
        case .cloudWithLocalFallback:
            return (cloudRoute, localRoute, false)
        }
    }

    private func speak(_ raw: String,
                       captureMethod: SelectionCapture.Method,
                       routingAction: RoutingPolicy.Action) {
        guard raw.count <= Chunker.maxReadCharacters else {
            reportError("Selection is too large (maximum \(Chunker.maxReadCharacters.formatted()) characters).")
            return
        }
        preparationGeneration += 1
        let preparation = preparationGeneration
        preparationTask?.cancel()
        preparationTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                () -> (String, [Chunk])? in
                guard !Task.isCancelled else { return nil }
                let normalized = Normalizer.normalize(raw)
                guard !Task.isCancelled else { return nil }
                let chunks = Chunker.split(normalized)
                guard !Task.isCancelled else { return nil }
                return (normalized, chunks)
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  self.preparationGeneration == preparation,
                  let prepared else { return }
            self.preparationTask = nil
            self.beginPreparedSpeak(
                normalized: prepared.0,
                chunks: prepared.1,
                captureMethod: captureMethod,
                routingAction: routingAction)
        }
    }

    private func beginPreparedSpeak(
        normalized: String,
        chunks: [Chunk],
        captureMethod: SelectionCapture.Method,
        routingAction: RoutingPolicy.Action
    ) {
        guard !chunks.isEmpty else {
            flashStatus("Nothing to speak")
            return
        }
        guard normalized.count <= Chunker.maxReadCharacters else {
            reportError("Selection is too large (maximum \(Chunker.maxReadCharacters.formatted()) characters).")
            return
        }
        guard var routes = resolveRoutes(routingAction: routingAction) else { return }

        // Budget gate (C-2) — cloud reads only.
        if !routes.isLocal {
            switch ledger.verdict() {
            case .exceeded(let spent, let budget):
                if let localChoice = budgetExceededDialog(spent: spent, budget: budget) {
                    if localChoice {
                        guard let local = resolveLocalOnlyRoute() else { return }
                        routes = (local, nil, true)
                    } // else: override chosen, continue on cloud
                } else {
                    return
                }
            case .warning(let spent, let budget):
                flashStatus("Budget: \(spent.formatted()) of \(budget.formatted()) credits today")
            case .ok:
                break
            }
        }

        // Large-read confirmation (C-3) — cloud reads only.
        if !routes.isLocal && normalized.count >= ledger.largeReadThreshold {
            switch largeReadDialog(characters: normalized.count) {
            case .cancel:
                return
            case .speakLocally:
                guard let local = resolveLocalOnlyRoute() else { return }
                routes = (local, nil, true)
            case .speakCloud:
                break
            }
        }

        SRLog.event("speak.start", [
            "capture": captureMethod.rawValue,
            "chars": String(normalized.count),
            "sentences": String(chunks.count),
            "backend": routes.isLocal ? "local" : "cloud",
        ])

        // Cancel the old pipeline BEFORE starting the new session, and tag
        // this run: an old chunk already past its cancellation check would
        // otherwise deliver the previous text's audio into the new timeline.
        pipeline.cancel()
        speakGeneration += 1
        let generation = speakGeneration

        playback.startSession(totalSentences: chunks.count)
        activeUsesCloud = !routes.isLocal
        activeBackend = routes.isLocal ? .local : .cloud
        playback.onFinished = { [weak self] in
            self?.activeUsesCloud = false
            self?.activeBackend = nil
            self?.refreshCredits()
            self?.refreshCacheSize()
        }
        playback.onError = { [weak self] message in
            guard let self else { return }
            self.pipeline.cancel()
            self.activeUsesCloud = false
            self.activeBackend = nil
            self.reportError(message)
            NSSound.beep()
        }

        let deleteHistory = autoDeleteHistory
        let janitor = janitor
        let ledger = ledger
        let cloudBudgetRemaining = !routes.isLocal && !ledger.overriddenToday
            ? max(ledger.dailyBudget - ledger.spentToday, 0)
            : nil
        pipeline.run(
            chunks: chunks,
            primary: routes.primary,
            fallback: routes.fallback,
            settings: settings.voiceSettings,
            cache: cacheEnabled ? AudioCache.shared : nil,
            cloudBudgetRemaining: cloudBudgetRemaining,
            shouldSynthesize: { [weak self] index in
                guard let self, self.speakGeneration == generation else { return false }
                return SynthesisPipeline.needsChunk(
                    index, currentSentence: self.playback.currentSentence,
                    isPlaying: self.playback.state == .playing)
            },
            callbacks: .init(
                deliver: { [weak self] index, audio in
                    guard let self, self.speakGeneration == generation else { return }
                    self.playback.feed(index: index, audio: audio)
                },
                billed: { [weak self] billed in
                    ledger.record(billedCharacters: billed)
                    Task { @MainActor [weak self] in
                        self?.spentToday = ledger.spentToday
                    }
                },
                historyID: { [self] id in
                    guard deleteHistory else { return }
                    Task {
                        await janitor.enqueue(id)
                        let line = await janitor.statusLine
                        await MainActor.run { historyStatus = line }
                    }
                },
                fellBack: { [weak self] in
                    guard let self, self.speakGeneration == generation else { return }
                    // A fallback only reroutes future chunks. Other workers
                    // may still have cloud requests in flight, so retain the
                    // cloud flag until this session finishes or is stopped.
                    self.activeBackend = .local
                    self.flashStatus("Cloud unavailable — switched to local voice")
                },
                failed: { [weak self] error in
                    guard let self, self.speakGeneration == generation else { return }
                    self.handleSynthesisError(error)
                }
            )
        )
    }

    private func resolveLocalOnlyRoute() -> SynthesisPipeline.Route? {
        guard KokoroRuntime.shared.isInstalled else {
            reportError("Offline voices aren't installed yet.", action: .installOffline)
            return nil
        }
        return SynthesisPipeline.Route(
            provider: KokoroProvider(), voiceID: localVoiceID, modelID: KokoroProvider.cacheModelID)
    }

    // MARK: - Dialogs (C-2 / C-3)

    /// Returns nil = cancel; false = override budget (speak cloud); true = speak locally.
    private func budgetExceededDialog(spent: Int, budget: Int) -> Bool? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Daily budget reached"
        alert.informativeText =
            "You've spent \(spent.formatted()) of your \(budget.formatted())-credit daily budget."
        alert.addButton(withTitle: KokoroRuntime.shared.isInstalled
            ? "Speak Locally (free)" : "Cancel")
        alert.addButton(withTitle: "Override for Today")
        if KokoroRuntime.shared.isInstalled {
            alert.addButton(withTitle: "Cancel")
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return KokoroRuntime.shared.isInstalled ? true : nil
        case .alertSecondButtonReturn:
            ledger.overriddenToday = true
            budgetOverriddenToday = true
            return false
        default:
            return nil
        }
    }

    private enum LargeReadChoice { case speakCloud, speakLocally, cancel }

    private func largeReadDialog(characters: Int) -> LargeReadChoice {
        NSApp.activate(ignoringOtherApps: true)
        let info = ElevenLabsProvider.modelInfo(for: modelID)
        let multiplier = info?.creditMultiplier ?? 1.0
        let modelName = info?.shortName ?? modelID
        let estCredits = Int((Double(characters) * multiplier).rounded())
        let rateLabel = multiplier < 1.0 ? "0.5×" : "1×"

        let alert = NSAlert()
        alert.messageText = "Large selection"
        alert.informativeText =
            "\(characters.formatted()) characters — ≈\(estCredits.formatted()) credits on \(modelName) (\(rateLabel))."
        alert.addButton(withTitle: "Speak with ElevenLabs")
        if KokoroRuntime.shared.isInstalled {
            alert.addButton(withTitle: "Speak Locally (free)")
        }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .speakCloud
        case .alertSecondButtonReturn where KokoroRuntime.shared.isInstalled:
            return .speakLocally
        default:
            return .cancel
        }
    }

    // MARK: - Kokoro install & daemon (P-12)

    func installKokoro() {
        guard kokoroInstallStatus == nil else { return }
        guard let source = daemonScriptSource(),
              let requirementsLock = requirementsLockSource() else {
            reportError("Offline voice installer resources are missing from the app bundle.")
            return
        }
        dismissError()
        kokoroInstallStatus = "Starting…"
        // Strong capture: install must outlive any UI churn, and AppState
        // lives for the app's lifetime.
        installTask = Task { [self] in
            defer { installTask = nil }
            for await progress in KokoroRuntime.shared.installer.install(
                daemonSourceURL: source,
                requirementsLockURL: requirementsLock) {
                switch progress {
                case .creatingVenv: kokoroInstallStatus = "Creating Python environment…"
                case .installingPackages: kokoroInstallStatus = "Installing mlx-audio…"
                case .downloadingModel: kokoroInstallStatus = "Downloading Kokoro model (~330 MB)…"
                case .verifying: kokoroInstallStatus = "Verifying checksums…"
                case .done:
                    kokoroInstallStatus = nil
                    kokoroInstalled = true
                    kokoroNeedsUpdate = false
                    flashStatus("Offline voices installed — warming up…")
                    prewarmKokoroIfNeeded()
                case .failed(let message):
                    kokoroInstallStatus = nil
                    reportError("Offline voice install failed: \(message)")
                }
            }
        }
    }

    func refreshKokoroDaemonStatus() {
        guard servicesEnabled else { return }
        Task { [weak self] in
            let running = await KokoroRuntime.shared.supervisor.isRunning
            await MainActor.run {
                self?.kokoroDaemonRunning = running
            }
        }
    }

    func restartKokoroDaemon() {
        guard servicesEnabled, kokoroInstalled else { return }
        let voice = localVoiceID
        flashStatus("Restarting offline voice engine…")
        Task { [weak self] in
            do {
                try await KokoroRuntime.shared.supervisor.restart(warmupVoice: voice)
                await MainActor.run {
                    self?.kokoroDaemonRunning = true
                    self?.dismissError()
                    self?.flashStatus("Offline voice engine ready")
                }
            } catch {
                await MainActor.run {
                    self?.kokoroDaemonRunning = false
                    self?.reportError("Could not restart offline voice engine.")
                }
            }
        }
    }

    private func daemonScriptSource() -> URL? {
        if let bundled = Bundle.main.url(forResource: "sr_tts_server", withExtension: "py") {
            return bundled
        }
        // Dev fallback: running from the repo via `swift run`.
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("daemon/sr_tts_server.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private func requirementsLockSource() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "kokoro-requirements", withExtension: "lock") {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("daemon/requirements.lock")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // MARK: - Cache & Settings actions (P-10)

    func purgeCache() {
        AudioCache.shared.purge()
        cacheSizeBytes = 0
        flashStatus("Audio cache purged")
    }

    func refreshCacheSize() {
        guard servicesEnabled else { return }
        Task(priority: .utility) { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                AudioCache.shared.currentSizeBytes()
            }.value
            self?.cacheSizeBytes = bytes
        }
    }

    func resetVoiceSettingsToDefaults() {
        let defaults = VoiceSettings()
        voiceStability = defaults.stability
        voiceSimilarityBoost = defaults.similarityBoost
    }

    func resetBudgetOverride() {
        ledger.overriddenToday = false
        budgetOverriddenToday = false
        flashStatus("Daily budget re-enabled")
    }

    func revealRulesFile() {
        let url = RoutingPolicy.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            RoutingPolicy.load().save()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func onMenuAppear() {
        guard servicesEnabled else { return }
        accessibilityGranted = AXIsProcessTrusted()
        spentToday = ledger.spentToday
        budgetOverriddenToday = ledger.overriddenToday
        refreshVoices()
        refreshCredits()
        refreshKokoroDaemonStatus()
    }

    // MARK: - Error surface (F-11)

    private func handleSynthesisError(_ error: TTSError) {
        stop()
        NSSound.beep()
        switch error {
        case .missingAPIKey:
            reportError("No ElevenLabs API key — add one in Settings.", action: .openSettings)
        case .http(401, _), .http(403, _):
            reportError("ElevenLabs auth failed — check your API key.", action: .openSettings)
        case .http(402, _):
            reportError("This voice needs a paid ElevenLabs plan — pick another voice.")
        case .http(429, _):
            reportError("ElevenLabs quota exceeded.")
        case .http(let status, _):
            reportError("Synthesis error (HTTP \(status)).")
        case .invalidAudio:
            reportError("ElevenLabs returned invalid audio; the read was stopped.")
        case .network("kokoro: incompatible daemon"):
            reportError("Offline engine updated — restart it in Settings or reopen sr.", action: .openSettings)
        case .network(let detail) where detail.hasPrefix("kokoro"):
            reportError("Offline voice unavailable — check Settings → Offline Voices.", action: .openSettings)
        case .network:
            reportError("Could not reach ElevenLabs.")
        case .cancelled:
            return
        case .budgetExceeded:
            reportError("Daily cloud budget reached — the remaining text was not sent.")
        }
    }

    // MARK: - Voices & Credits (F-10, C-1)

    func refreshVoices(force: Bool = false) {
        guard servicesEnabled else { return }
        if !force, let at = voicesFetchedAt, Date().timeIntervalSince(at) < 3600 { return }
        Task { [weak self] in
            guard let self else { return }
            guard let voices = try? await ElevenLabsProvider().voices(), !voices.isEmpty else { return }
            self.availableVoices = voices
            self.voicesFetchedAt = Date()
            // If the selected voice isn't present in this account's usable
            // voice list (including a stale/deprecated default preset), switch
            // cleanly to the first available voice instead of hitting 402/404.
            if !voices.contains(where: { $0.id == self.voiceID }) {
                self.voiceID = voices[0].id
            }
        }
    }

    func refreshCredits() {
        guard servicesEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let sub = try? await ElevenLabsProvider().subscription() else { return }
            self.creditsRemaining = sub.remaining
            self.creditsLimit = sub.characterLimit
        }
    }

    // MARK: - Shortcuts

    func resetShortcutsToDefaults() {
        KeyboardShortcuts.reset(.speakOrStop, .pauseResume)
    }

    // MARK: - Accessibility onboarding

    func promptForAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled && !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
                if self == nil { return }
            }
            guard !Task.isCancelled else { return }
            self?.accessibilityGranted = true
            self?.accessibilityPollTask = nil
        }
    }

    // MARK: - Helpers

    private func flashStatus(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.statusMessage = nil }
        }
    }
}
