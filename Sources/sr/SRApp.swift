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

        // Real window: unlike the MenuBarExtra panel it becomes key, so the
        // shortcut recorders and the API-key field actually receive input.
        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

// MARK: - Menu panel (quick controls only; text input lives in Settings)

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

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
            Divider()
            bottomRow
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .onAppear { state.refreshVoices() }
    }

    // MARK: Transport (F-7 subset)

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
            case .paused(let s, let n):
                Text("Paused — sentence \(s + 1) of \(n)")
            case .idle:
                Text("Select text, press \(shortcutHint)")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var shortcutHint: String {
        KeyboardShortcuts.getShortcut(for: .speakOrStop)?.description ?? "the hotkey (unset)"
    }

    // MARK: Speed (F-8)

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

    // MARK: Backend & voices (F-3, P-8 Local-Only)

    private var backendPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("Backend", selection: $state.backendMode) {
                Text("Auto").tag(SettingsStore.BackendMode.auto)
                Text("Cloud").tag(SettingsStore.BackendMode.cloud)
                Text("Local 🔒").tag(SettingsStore.BackendMode.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(backendCaption)
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var backendCaption: String {
        switch state.backendMode {
        case .auto: return "Cloud voices, local fallback if the cloud fails"
        case .cloud: return "ElevenLabs only"
        case .local: return "Nothing ever leaves this Mac"
        }
    }

    @ViewBuilder
    private var voicePickers: some View {
        if state.backendMode != .local {
            Picker("Voice", selection: $state.voiceID) {
                ForEach(state.availableVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
                if !state.availableVoices.contains(where: { $0.id == state.voiceID }) {
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

    // MARK: Privacy & status (P-6, P-10, C-1/C-2)

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Auto-delete ElevenLabs history", isOn: $state.autoDeleteHistory)
                .toggleStyle(.checkbox)
            Toggle("Cache audio", isOn: $state.cacheEnabled)
                .toggleStyle(.checkbox)
                .help("Disable for sensitive sessions — nothing is written to disk")
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
                Label("Grant Accessibility (reads your selection)", systemImage: "exclamationmark.triangle")
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
        if !state.kokoroInstalled && state.kokoroInstallStatus == nil {
            Button("Install Local Voice (Kokoro, ~330 MB)…") {
                state.installKokoro()
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        HStack(spacing: 4) {
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

    private var bottomRow: some View {
        HStack {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Spacer()
            Button("Quit sr") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft = ""
    @State private var apiKeySavedFlash = false

    var body: some View {
        Form {
            Section("Hotkeys") {
                KeyboardShortcuts.Recorder("Speak / Stop:", name: .speakOrStop)
                KeyboardShortcuts.Recorder("Pause / Resume:", name: .pauseResume)
                Button("Reset Shortcuts to Defaults") {
                    state.resetShortcutsToDefaults()
                }
            }

            Section("ElevenLabs") {
                HStack {
                    SecureField(
                        KeychainStore.maskedAPIKey() ?? "API key",
                        text: $apiKeyDraft
                    )
                    Button("Save") {
                        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        KeychainStore.saveAPIKey(trimmed)
                        apiKeyDraft = ""
                        apiKeySavedFlash = true
                        state.refreshCredits()
                        state.refreshVoices(force: true)
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            apiKeySavedFlash = false
                        }
                    }
                }
                if apiKeySavedFlash {
                    Text("Saved to Keychain").font(.caption).foregroundStyle(.green)
                }
                Text("Stored only in the macOS Keychain. Scope the key to Text-to-Speech + User Read.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cost") {
                let ledger = state.ledger
                LabeledContent("Daily budget") {
                    TextField("characters", value: Binding(
                        get: { ledger.dailyBudget },
                        set: { ledger.dailyBudget = max(0, $0) }
                    ), format: .number)
                    .frame(width: 100)
                }
                LabeledContent("Confirm reads above") {
                    TextField("characters", value: Binding(
                        get: { ledger.largeReadThreshold },
                        set: { ledger.largeReadThreshold = max(0, $0) }
                    ), format: .number)
                    .frame(width: 100)
                }
            }

            Section("Maintenance") {
                Button("Purge Audio Cache") { state.purgeCache() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
