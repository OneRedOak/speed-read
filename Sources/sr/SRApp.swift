import KeyboardShortcuts
import SRCore
import SwiftUI

@MainActor
final class SRAppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await SRAppDelegate.state?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct SRApp: App {
    @NSApplicationDelegateAdaptor(SRAppDelegate.self) private var appDelegate
    @StateObject private var state: AppState

    init() {
        // Wire the delegate here, not in MenuView.onAppear: MenuBarExtra
        // content is built lazily on first open, so a quit before the menu
        // was ever opened would find state == nil and skip shutdown()
        // (pending history deletes lost, daemon left to the watchdog).
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        SRAppDelegate.state = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("sr", systemImage: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(state.playback.isActive ? (isPaused ? "Paused" : "Reading") : "Ready to read")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                transportCluster
                progressSection
                Divider()
                speedSection
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))

            Button { state.speakClipboard() } label: {
                Label("Read Clipboard", systemImage: "doc.on.clipboard")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Read the text currently on your clipboard")

            VStack(alignment: .leading, spacing: 12) {
                BackendSelector(selection: $state.backendMode)
                Text(backendCaption).font(.callout).foregroundStyle(.secondary)
                voicePickers
            }
            statusSection
            Divider()
            HStack {
                Button { showSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Spacer()
                Button("Quit sr") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
            .buttonStyle(.borderless)
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { state.refreshVoices(); state.refreshCredits() }
    }

    private var isPaused: Bool { state.playback.state == .paused }

    private var transportCluster: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            TransportButton(systemName: "backward.end.fill", size: 34, iconSize: 13,
                            help: "Restart reading") { state.playback.restart() }
            TransportButton(systemName: "gobackward.5", size: 38, iconSize: 19,
                            help: "Back 5 seconds") { state.playback.seek(by: -5) }
            TransportButton(systemName: isPaused || !state.playback.isActive ? "play.fill" : "pause.fill",
                            size: 52, iconSize: 21, prominent: true,
                            help: isPaused ? "Resume reading" : "Pause reading") {
                state.playback.togglePauseResume()
            }
            TransportButton(systemName: "goforward.5", size: 38, iconSize: 19,
                            help: "Forward 5 seconds") { state.playback.seek(by: 5) }
            TransportButton(systemName: "stop.fill", size: 34, iconSize: 13,
                            help: "Stop reading") { state.stop() }
            Spacer(minLength: 0)
        }
        .disabled(!state.playback.isActive)
    }

    @ViewBuilder private var progressSection: some View {
        if state.playback.isActive {
            VStack(spacing: 8) {
                ProgressView(value: min(state.playback.currentSeconds, state.playback.availableSeconds),
                             total: max(state.playback.availableSeconds, 0.01))
                    .tint(.accentColor)
                    .accessibilityLabel("Reading progress")
                HStack {
                    Text("Sentence \(state.playback.currentSentence + 1) of \(state.playback.totalSentences)")
                    Spacer()
                    Text(timeString(state.playback.currentSeconds)).monospacedDigit()
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 4) {
                Text("Select text in any app")
                    .font(.body.weight(.medium))
                Text("Press \(shortcutHint) to read it aloud")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var speedSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Reading speed").font(.callout.weight(.medium))
                Spacer()
                Text(state.playbackRate.formatted(.number.precision(.fractionLength(0...2))) + "×")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Slider(value: $state.playbackRate, in: 0.5...3.0, step: 0.05)
                .accessibilityLabel("Reading speed")
                .accessibilityValue(state.playbackRate.formatted() + " times")
            HStack(spacing: 8) {
                ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { preset in
                    SpeedChip(value: preset, isActive: abs(state.playbackRate - preset) < 0.01) {
                        state.playbackRate = preset
                    }
                }
            }
        }
    }

    private var backendCaption: String {
        switch state.backendMode {
        case .auto: return "ElevenLabs, with an offline fallback."
        case .cloud: return "ElevenLabs · uses your API credits"
        case .local: return "On this Mac · offline, no API costs"
        }
    }

    @ViewBuilder private var voicePickers: some View {
        if state.backendMode != .local {
            selectionMenu("Voice", value: state.availableVoices.first { $0.id == state.voiceID }?.name ?? "Custom voice") {
                Picker("Cloud voice", selection: $state.voiceID) {
                    ForEach(state.availableVoices) { Text($0.name).tag($0.id) }
                    if !state.availableVoices.contains(where: { $0.id == state.voiceID }) {
                        Text("Custom voice").tag(state.voiceID)
                    }
                }.labelsHidden()
            }
            selectionMenu("Model", value: ElevenLabsProvider.models.first { $0.id == state.modelID }?.name ?? state.modelID) {
                Picker("Cloud model", selection: $state.modelID) {
                    ForEach(ElevenLabsProvider.models, id: \.id) { Text($0.name).tag($0.id) }
                }.labelsHidden()
            }
        }
        if state.backendMode != .cloud {
            selectionMenu(state.backendMode == .auto ? "Offline voice" : "Voice",
                          value: KokoroProvider.presetVoices.first { $0.id == state.localVoiceID }?.name ?? "Custom local voice") {
                Picker("Local voice", selection: $state.localVoiceID) {
                    ForEach(KokoroProvider.presetVoices) { Text($0.name).tag($0.id) }
                }.labelsHidden()
            }
            .disabled(!state.kokoroInstalled)
            if state.backendMode == .local {
                selectionMenu("Model", value: "Kokoro v1.0 · 82M") {
                    Picker("Local model", selection: .constant(KokoroProvider.cacheModelID)) {
                        Text("Kokoro v1.0 · 82M (installed)").tag(KokoroProvider.cacheModelID)
                    }.labelsHidden()
                }
                .disabled(!state.kokoroInstalled)
            }
        }
    }

    private func selectionMenu<Content: View>(_ title: String, value: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Menu(content: content) {
                Text(value).lineLimit(1).truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(value)
            .accessibilityLabel(title + ": " + value)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.accessibilityGranted {
                Button { state.promptForAccessibility() } label: {
                    Label("Enable reading selected text", systemImage: "exclamationmark.triangle")
                }.buttonStyle(.borderless)
            }
            if let message = state.statusMessage {
                Label(message, systemImage: state.lastError == message ? "exclamationmark.triangle" : "info.circle")
                    .font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            if let status = state.kokoroInstallStatus {
                HStack { ProgressView().controlSize(.small); Text(status).font(.callout) }
            } else if !state.kokoroInstalled {
                Button(state.kokoroNeedsUpdate ? "Update offline voices…" : "Install offline voices…") {
                    state.installKokoro()
                }.buttonStyle(.bordered)
            }
            if state.backendMode != .local, let remaining = state.creditsRemaining {
                HStack {
                    Label("\(remaining.formatted()) credits left", systemImage: "cloud")
                    Spacer()
                    Text("\(state.ledger.spentToday.formatted()) today")
                }.font(.caption).foregroundStyle(.secondary)
            } else if state.backendMode == .local, state.kokoroInstalled {
                Label("Kokoro installed · MLX Audio \(KokoroInstaller.mlxAudioVersion)", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private var shortcutHint: String {
        KeyboardShortcuts.getShortcut(for: .speakOrStop)?.description ?? "your shortcut (set in Settings)"
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Transport components

/// Circular transport control with a hover ring and a full-circle hit area.
/// `prominent` renders as the accent-filled hero (play/pause).
private struct TransportButton: View {
    let systemName: String
    var size: CGFloat = 36
    var iconSize: CGFloat = 15
    var prominent = false
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                if prominent {
                    Circle().fill(Color.accentColor)
                    if hovering && isEnabled {
                        Circle().fill(.white.opacity(0.15))
                    }
                } else if hovering && isEnabled {
                    Circle().fill(.quaternary)
                }
                Image(systemName: systemName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(prominent ? AnyShapeStyle(.white)
                                               : AnyShapeStyle(.primary))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Full-width backend selector styled to match the panel's rounded
/// language (same radius family as the Speak Clipboard button): a soft
/// container, equal-width segments, accent fill on the active one.
private struct BackendSelector: View {
    @Binding var selection: SettingsStore.BackendMode

    var body: some View {
        HStack(spacing: 3) {
            segment(.auto, title: "Auto", icon: nil,
                    help: "Cloud voices, local fallback if the cloud fails")
            segment(.cloud, title: "Cloud", icon: nil,
                    help: "ElevenLabs only")
            segment(.local, title: "Local", icon: "lock.fill",
                    help: "Nothing ever leaves this Mac")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .animation(.easeOut(duration: 0.15), value: selection)
    }

    private func segment(_ mode: SettingsStore.BackendMode,
                         title: String, icon: String?, help: String) -> some View {
        BackendSegment(
            title: title,
            icon: icon,
            isActive: selection == mode,
            help: help
        ) {
            selection = mode
        }
    }
}

private struct BackendSegment: View {
    let title: String
    let icon: String?
    let isActive: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(isActive ? 1 : 0.55)
                }
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive
                        ? AnyShapeStyle(Color.accentColor)
                        : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One-click speed preset.
private struct SpeedChip: View {
    let value: Double
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout.monospacedDigit().weight(isActive ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isActive
                        ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                        : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25),
                        lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var label: String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft = ""
    @State private var apiKeySavedFlash = false
    @State private var apiKeySaveError: String?

    var body: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Speak / Stop:") {
                    ShortcutRecorderField(name: .speakOrStop)
                }
                LabeledContent("Pause / Resume:") {
                    ShortcutRecorderField(name: .pauseResume)
                }
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
                        guard KeychainStore.saveAPIKey(trimmed) else {
                            apiKeySavedFlash = false
                            apiKeySaveError = "Keychain rejected the update. Unlock your login keychain and try again."
                            return
                        }
                        apiKeyDraft = ""
                        apiKeySavedFlash = true
                        apiKeySaveError = nil
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
                if let apiKeySaveError {
                    Text(apiKeySaveError).font(.caption).foregroundStyle(.red)
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

            Section("Privacy & Storage") {
                Toggle("Auto-delete ElevenLabs history", isOn: $state.autoDeleteHistory)
                Text("Removes cloud generations from your ElevenLabs history after synthesis.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Cache audio for free replays", isOn: $state.cacheEnabled)
                Text("Turn off caching for sensitive reads. Existing audio stays until you purge it.")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.historyStatus.isEmpty {
                    Text(state.historyStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Offline Voices") {
                LabeledContent("Model", value: "Kokoro v1.0 · 82M")
                LabeledContent("Runtime", value: "MLX Audio \(KokoroInstaller.mlxAudioVersion)")
                LabeledContent("Status", value: state.kokoroInstalled ? "Installed" : "Update or installation required")
                Text("Includes Heart, Bella, Michael, and other English voices. Choose Local or Auto in the reader to select a voice.")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.kokoroInstalled {
                    Button(state.kokoroNeedsUpdate ? "Update Offline Voices" : "Install Offline Voices") { state.installKokoro() }
                        .disabled(state.kokoroInstallStatus != nil)
                }
                if let status = state.kokoroInstallStatus { Text(status).font(.caption) }
            }

            Section("Maintenance") {
                Button("Purge Audio Cache") { state.purgeCache() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 680)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // The Settings window can open behind the menu bar panel;
            // bring it to front once it exists.
            DispatchQueue.main.async {
                NSApp.windows
                    .first { $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("Settings") }?
                    .makeKeyAndOrderFront(nil)
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
