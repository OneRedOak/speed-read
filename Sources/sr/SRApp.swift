import KeyboardShortcuts
import SRCore
import SwiftUI

final class SRAppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            SRAppDelegate.state?.shutdown()
        }
    }
}

@main
struct SRApp: App {
    @NSApplicationDelegateAdaptor(SRAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
                .onAppear { SRAppDelegate.state = state }
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
            backendPicker
            voicePickers
            Divider()
            privacySection
            statusSection
            actionsSection
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Transport (F-7 subset)

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

    // MARK: - Backend & voices (F-3, P-8 Local-Only)

    private var backendPicker: some View {
        Picker(selection: $state.backendMode) {
            Text("Auto (cloud → local)").tag(SettingsStore.BackendMode.auto)
            Text("Cloud only").tag(SettingsStore.BackendMode.cloud)
            Text("Local only 🔒").tag(SettingsStore.BackendMode.local)
        } label: {
            Text("Backend")
        }
        .pickerStyle(.segmented)
        .help("Local only guarantees no text ever leaves this Mac")
    }

    @ViewBuilder
    private var voicePickers: some View {
        if state.backendMode != .local {
            Picker("Voice", selection: $state.voiceID) {
                ForEach(ElevenLabsProvider.presetVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
                if !ElevenLabsProvider.presetVoices.contains(where: { $0.id == state.voiceID }) {
                    Text("Custom (\(String(state.voiceID.prefix(8)))…)").tag(state.voiceID)
                }
            }
            Picker("Model", selection: $state.modelID) {
                ForEach(ElevenLabsProvider.models, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }
        }
        if state.kokoroInstalled && state.backendMode != .cloud {
            Picker("Local voice", selection: $state.localVoiceID) {
                ForEach(KokoroProvider.presetVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }
        }
    }

    // MARK: - Privacy & cost (P-6, P-10, C-1/C-2)

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Auto-delete ElevenLabs history", isOn: $state.autoDeleteHistory)
                .toggleStyle(.checkbox)
                .help("Best-effort: deletes each generation from your account right after synthesis")
            Toggle("Cache audio (disable for sensitive sessions)", isOn: $state.cacheEnabled)
                .toggleStyle(.checkbox)
            if !state.historyStatus.isEmpty {
                Text(state.historyStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

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
        if let installStatus = state.kokoroInstallStatus {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(installStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        HStack {
            if let remaining = state.creditsRemaining, let limit = state.creditsLimit {
                Text("Credits: \(remaining.formatted()) / \(limit.formatted())")
            }
            let spent = state.ledger.spentToday
            if spent > 0 {
                Text("· today: \(spent.formatted())")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
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

            if !state.kokoroInstalled && state.kokoroInstallStatus == nil {
                Button("Install Local Voice (Kokoro, ~330 MB)…") {
                    state.installKokoro()
                }
                .buttonStyle(.borderless)
            }

            Button("Purge Audio Cache") {
                state.purgeCache()
            }
            .buttonStyle(.borderless)

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
