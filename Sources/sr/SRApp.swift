import KeyboardShortcuts
import SRCore
import SwiftUI

@main
struct SRApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.playback.isActive
                  ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @State private var showingAPIKeyEntry = false
    @State private var apiKeyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            transportRow
            progressRow
            speedRow
            Divider()
            voicePicker
            modelPicker
            Divider()
            statusSection
            actionsSection
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Transport (F-7 subset for Phase 1)

    private var transportRow: some View {
        HStack(spacing: 14) {
            Button {
                state.playback.togglePauseResume()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .imageScale(.large)
            }
            .disabled(!state.playback.isActive)

            Button {
                state.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .imageScale(.large)
            }
            .disabled(!state.playback.isActive)

            Spacer()

            Button("Speak Clipboard") {
                state.speakClipboard()
            }
        }
        .buttonStyle(.borderless)
    }

    private var isPaused: Bool {
        if case .paused = state.playback.state { return true }
        return false
    }

    private var progressRow: some View {
        Group {
            switch state.playback.state {
            case .playing(let s, let n):
                Text("Sentence \(s + 1) of \(n)")
                    .font(.caption).foregroundStyle(.secondary)
            case .paused(let s, let n):
                Text("Paused — sentence \(s + 1) of \(n)")
                    .font(.caption).foregroundStyle(.secondary)
            case .idle:
                Text("Select text, press ⌥⇧/")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Speed (F-8)

    private var speedRow: some View {
        HStack {
            Image(systemName: "tortoise").imageScale(.small)
            Slider(value: $state.playbackRate, in: 0.5...3.0, step: 0.1)
            Image(systemName: "hare").imageScale(.small)
            Text(String(format: "%.1f×", state.playbackRate))
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - Voice & model

    private var voicePicker: some View {
        Picker("Voice", selection: $state.voiceID) {
            ForEach(ElevenLabsProvider.presetVoices) { voice in
                Text(voice.name).tag(voice.id)
            }
            if !ElevenLabsProvider.presetVoices.contains(where: { $0.id == state.voiceID }) {
                Text("Custom (\(String(state.voiceID.prefix(8)))…)").tag(state.voiceID)
            }
        }
    }

    private var modelPicker: some View {
        Picker("Model", selection: $state.modelID) {
            ForEach(ElevenLabsProvider.models, id: \.id) { model in
                Text(model.name).tag(model.id)
            }
        }
    }

    // MARK: - Status & actions

    @ViewBuilder
    private var statusSection: some View {
        if !state.accessibilityGranted {
            Button {
                state.promptForAccessibility()
            } label: {
                Label("Enable Accessibility for hotkeys", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
        }
        if let message = state.statusMessage {
            Text(message).font(.caption).foregroundStyle(.orange)
        }
        if let remaining = state.creditsRemaining, let limit = state.creditsLimit {
            Text("Credits: \(remaining.formatted()) / \(limit.formatted())")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showingAPIKeyEntry {
                HStack {
                    SecureField(
                        KeychainStore.maskedAPIKey() ?? "ElevenLabs API key",
                        text: $apiKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            KeychainStore.saveAPIKey(trimmed)
                            state.refreshCredits()
                        }
                        apiKeyDraft = ""
                        showingAPIKeyEntry = false
                    }
                }
            } else {
                Button(KeychainStore.readAPIKey() == nil
                       ? "Add ElevenLabs API Key…"
                       : "Change API Key…") {
                    showingAPIKeyEntry = true
                }
                .buttonStyle(.borderless)
            }

            HStack {
                KeyboardShortcuts.Recorder("Speak/Stop:", name: .speakOrStop)
                    .font(.caption)
            }
            HStack {
                KeyboardShortcuts.Recorder("Pause/Resume:", name: .pauseResume)
                    .font(.caption)
            }

            Divider()
            Button("Quit sr") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }
}
