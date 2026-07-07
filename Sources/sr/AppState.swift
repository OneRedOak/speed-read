import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import SRCore
import SwiftUI

extension KeyboardShortcuts.Name {
    /// ⌥⇧/ — speak selection, or stop if speaking (F-1, F-2).
    static let speakOrStop = Self("speakOrStop",
        default: .init(.slash, modifiers: [.option, .shift]))
    /// ⌥⇧. — pause/resume (F-2).
    static let pauseResume = Self("pauseResume",
        default: .init(.period, modifiers: [.option, .shift]))
}

/// Central controller: hotkeys → capture → normalize → chunk → synthesize
/// → play. Owns all mutable app state; the SwiftUI menu observes it.
@MainActor
final class AppState: ObservableObject {
    let settings = SettingsStore()
    let playback: PlaybackEngine
    private let pipeline = SynthesisPipeline()

    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published var creditsRemaining: Int?
    @Published var creditsLimit: Int?
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    @Published var playbackRate: Double {
        didSet {
            settings.playbackRate = playbackRate
            playback.rate = playbackRate
        }
    }
    @Published var voiceID: String {
        didSet { settings.voiceID = voiceID }
    }
    @Published var modelID: String {
        didSet { settings.modelID = modelID }
    }

    private var statusClearTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let store = SettingsStore()
        playback = PlaybackEngine(rate: store.playbackRate,
                                  sentencePauseMS: store.sentencePauseMS)
        playbackRate = store.playbackRate
        voiceID = store.voiceID
        modelID = store.modelID

        KeyboardShortcuts.onKeyDown(for: .speakOrStop) { [weak self] in
            Task { @MainActor in self?.speakOrStop() }
        }
        KeyboardShortcuts.onKeyDown(for: .pauseResume) { [weak self] in
            Task { @MainActor in self?.playback.togglePauseResume() }
        }

        // Surface nested PlaybackEngine changes to views observing AppState.
        playback.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if !accessibilityGranted {
            promptForAccessibility()
        }
        refreshCredits()
    }

    // MARK: - Primary flows

    func speakOrStop() {
        if playback.isActive {
            stop()
            return
        }
        // Capture must run off the main thread: the ⌘C fallback sleeps
        // while polling the pasteboard. Strong capture is fine — AppState
        // lives for the app's lifetime and the task is short.
        Task.detached { [self] in
            let result = SelectionCapture.capture()
            await MainActor.run { handleCapture(result) }
        }
    }

    func speakClipboard() {
        if playback.isActive { stop() }
        handleCapture(SelectionCapture.clipboardText())
    }

    func stop() {
        pipeline.cancel()
        playback.stop()
    }

    private func handleCapture(_ result: SelectionCapture.CaptureResult) {
        switch result {
        case .accessibilityDenied:
            accessibilityGranted = false
            promptForAccessibility()
        case .concealed:
            NSSound.beep()
            flashStatus("Concealed content skipped")
        case .empty:
            NSSound.beep()
            flashStatus("No selection found")
        case .text(let raw, let method):
            speak(raw, captureMethod: method)
        }
    }

    private func speak(_ raw: String, captureMethod: SelectionCapture.Method) {
        let normalized = Normalizer.normalize(raw)
        let chunks = Chunker.split(normalized)
        guard !chunks.isEmpty else {
            flashStatus("Nothing to speak")
            return
        }
        SRLog.event("speak.start", [
            "capture": captureMethod.rawValue,
            "chars": String(normalized.count),
            "sentences": String(chunks.count),
        ])

        playback.startSession(totalSentences: chunks.count)
        playback.onFinished = { [weak self] in
            self?.refreshCredits()
        }

        let provider = ElevenLabsProvider(modelID: modelID)
        pipeline.run(
            chunks: chunks,
            provider: provider,
            voiceID: voiceID,
            settings: settings.voiceSettings,
            deliver: { [weak self] index, audio in
                self?.playback.feed(index: index, audio: audio)
            },
            failed: { [weak self] error in
                self?.handleSynthesisError(error)
            }
        )
    }

    private func handleSynthesisError(_ error: TTSError) {
        stop()
        NSSound.beep()
        switch error {
        case .missingAPIKey:
            lastError = "No ElevenLabs API key — add one in Settings."
        case .http(401, _), .http(403, _):
            lastError = "ElevenLabs auth failed — check your API key."
        case .http(429, _):
            lastError = "ElevenLabs quota exceeded."
        case .http(let status, _):
            lastError = "ElevenLabs error (HTTP \(status))."
        case .network:
            lastError = "Could not reach ElevenLabs."
        case .cancelled:
            return
        }
        flashStatus(lastError ?? "Error")
    }

    // MARK: - Credits (C-1)

    func refreshCredits() {
        Task { [weak self] in
            guard let self else { return }
            guard let sub = try? await ElevenLabsProvider().subscription() else { return }
            self.creditsRemaining = sub.remaining
            self.creditsLimit = sub.characterLimit
        }
    }

    // MARK: - Accessibility onboarding

    func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // Poll until granted so the UI banner clears without a relaunch.
        Task { @MainActor [weak self] in
            while !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
                if self == nil { return }
            }
            self?.accessibilityGranted = true
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
