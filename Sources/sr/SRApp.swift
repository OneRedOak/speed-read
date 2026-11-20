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
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            VStack(spacing: 12) {
                transportCluster
                progressSection
                Divider()
                speedSection
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button { state.speakClipboard() } label: {
                Label("Read Clipboard", systemImage: "doc.on.clipboard")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Read the text currently on your clipboard")

            VStack(alignment: .leading, spacing: 10) {
                BackendSelector(selection: $state.backendMode)
                Text(backendCaption).font(.caption).foregroundStyle(.secondary)
                voicePickers
            }

            statusSection

            Divider()

            HStack {
                Button { showSettings() } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button("Quit sr") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { state.onMenuAppear() }
    }

    private var isPaused: Bool { state.playback.state == .paused }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Label("sr", systemImage: "waveform")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            headerStatusPill
        }
    }

    @ViewBuilder private var headerStatusPill: some View {
        if state.playback.isActive {
            HStack(spacing: 6) {
                if state.playback.isBuffering {
                    ProgressView().controlSize(.mini)
                    Text("Preparing…")
                } else {
                    Circle()
                        .fill(isPaused ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(activeStatusText)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.65), in: Capsule())
        } else {
            Text("Ready to read")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var activeStatusText: String {
        let verb = isPaused ? "Paused" : "Reading"
        if let backend = state.activeBackend {
            return "\(verb) · \(backend.label)"
        }
        return verb
    }

    private var transportCluster: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            TransportButton(systemName: "backward.end.fill", size: 34, iconSize: 13,
                            help: "Restart reading") { state.playback.restart() }
            TransportButton(systemName: "gobackward.5", size: 38, iconSize: 19,
                            help: "Back 5 seconds (←)") { state.playback.seek(by: -5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            TransportButton(systemName: isPaused || !state.playback.isActive ? "play.fill" : "pause.fill",
                            size: 52, iconSize: 21, prominent: true,
                            help: isPaused ? "Resume reading (Space)" : "Pause reading (Space)") {
                state.playback.togglePauseResume()
            }
            .keyboardShortcut(.space, modifiers: [])
            TransportButton(systemName: "goforward.5", size: 38, iconSize: 19,
                            help: "Forward 5 seconds (→)") { state.playback.seek(by: 5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            TransportButton(systemName: "stop.fill", size: 34, iconSize: 13,
                            help: "Stop reading (⎋)") { state.stop() }
                .keyboardShortcut(.escape, modifiers: [])
            Spacer(minLength: 0)
        }
        .disabled(!state.playback.isActive)
    }

    @ViewBuilder private var progressSection: some View {
        if state.playback.isActive {
            VStack(spacing: 8) {
                ScrubbingProgressBar(
                    current: state.playback.currentSeconds,
                    available: state.playback.availableSeconds
                ) { targetSeconds in
                    state.playback.seek(toSeconds: targetSeconds)
                }
                HStack(spacing: 6) {
                    Button {
                        state.playback.skipSentence(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.playback.currentSentence > 0 ? .primary : .tertiary)
                    .disabled(state.playback.currentSentence == 0)
                    .help("Previous sentence")
                    .accessibilityLabel("Previous sentence")

                    Text("Sentence \(state.playback.currentSentence + 1) of \(state.playback.totalSentences)")
                        .monospacedDigit()

                    Button {
                        state.playback.skipSentence(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.playback.currentSentence + 1 < state.playback.decodedSentences ? .primary : .tertiary)
                    .disabled(state.playback.currentSentence + 1 >= state.playback.decodedSentences)
                    .help("Next sentence")
                    .accessibilityLabel("Next sentence")

                    Spacer()
                    Text(timeString(state.playback.currentSeconds)).monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
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
            HStack(spacing: 6) {
                ForEach([1.0, 1.25, 1.5, 2.0, 2.5], id: \.self) { preset in
                    SpeedChip(value: preset, isActive: abs(state.playbackRate - preset) < 0.01) {
                        state.setPlaybackRateImmediate(preset)
                    }
                }
            }
        }
    }

    private var backendCaption: String {
        let model = ElevenLabsProvider.modelInfo(for: state.modelID)
        let rateNote = (model?.creditMultiplier ?? 1.0) < 1.0 ? "0.5× credits" : "1× credits"
        switch state.backendMode {
        case .auto:
            return "ElevenLabs (\(rateNote)) · falls back to Kokoro offline"
        case .cloud:
            return "ElevenLabs · \(rateNote) per character"
        case .local:
            return "On this Mac · offline, zero API costs"
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
            selectionMenu("Model", value: ElevenLabsProvider.modelInfo(for: state.modelID)?.compactLabel ?? state.modelID) {
                Picker("Cloud model", selection: $state.modelID) {
                    ForEach(ElevenLabsProvider.models, id: \.id) { Text($0.name).tag($0.id) }
                }.labelsHidden()
            }
        }
        if state.backendMode != .cloud {
            selectionMenu(state.backendMode == .auto ? "Fallback" : "Voice",
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
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Menu(content: content) {
                HStack(spacing: 6) {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(value)
            .accessibilityLabel(title + ": " + value)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.accessibilityGranted {
                Button { state.promptForAccessibility() } label: {
                    Label("Enable reading selected text", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
            }

            if let error = state.lastError {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { state.dismissError() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss error")
                    }
                    if let action = state.errorAction {
                        switch action {
                        case .openSettings:
                            Button("Open Settings…") { showSettings() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        case .installOffline:
                            Button(state.kokoroNeedsUpdate ? "Update offline voices…" : "Install offline voices…") {
                                state.installKokoro()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let message = state.statusMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = state.kokoroInstallStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout)
                }
            } else if !state.kokoroInstalled && state.errorAction != .installOffline {
                Button(state.kokoroNeedsUpdate ? "Update offline voices…" : "Install offline voices…") {
                    state.installKokoro()
                }.buttonStyle(.bordered)
            }

            if state.backendMode != .local, let remaining = state.creditsRemaining {
                let nearLimit = !state.budgetOverriddenToday
                    && state.dailyBudget > 0
                    && Double(state.spentToday) >= Double(state.dailyBudget) * 0.8
                HStack {
                    Label("\(remaining.formatted()) credits left", systemImage: "cloud")
                    Spacer()
                    Text("\(state.spentToday.formatted()) today")
                        .foregroundStyle(nearLimit ? Color.orange : Color.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else if state.backendMode == .local, state.kokoroInstalled {
                HStack {
                    Label("Kokoro installed · MLX Audio \(KokoroInstaller.mlxAudioVersion)",
                          systemImage: "checkmark.circle")
                    Spacer()
                    Text(state.kokoroDaemonRunning ? "Warm" : "Standby")
                        .foregroundStyle(state.kokoroDaemonRunning ? Color.green : Color.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Transport & progress components

/// Interactive progress track over buffered audio: click or drag to scrub.
private struct ScrubbingProgressBar: View {
    let current: Double
    let available: Double
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    private var displayedFraction: Double {
        if let dragFraction { return dragFraction }
        guard available > 0.01 else { return 0 }
        return min(max(current / available, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 5)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(width * displayedFraction, available > 0.01 ? 5 : 0), height: 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard available > 0.01 else { return }
                        dragFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        guard available > 0.01 else {
                            dragFraction = nil
                            return
                        }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        dragFraction = nil
                        onSeek(fraction * available)
                    }
            )
        }
        .frame(height: 14)
        .accessibilityLabel("Reading progress")
        .accessibilityValue("\(Int((displayedFraction * 100).rounded())) percent")
    }
}

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
/// language: a soft container, equal-width segments, accent fill on the active one.
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
            .padding(.vertical, 8)
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

/// One-click speed preset chip. Uses a continuous rounded rectangle to match
/// the panel's shape language cleanly without macOS Capsule stroke artifacts.
private struct SpeedChip: View {
    let value: Double
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.monospacedDigit().weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive
                            ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                            : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.25),
                            lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Set speed to \(label)")
    }

    private var label: String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft = ""
    @State private var maskedAPIKey: String?
    @State private var apiKeyStatusMessage: String?
    @State private var apiKeyStatusIsError = false
    @State private var verifyingKey = false

    var body: some View {
        Form {
            Section("Hotkeys & Pacing") {
                LabeledContent("Speak / Stop:") {
                    ShortcutRecorderField(name: .speakOrStop)
                }
                LabeledContent("Pause / Resume:") {
                    ShortcutRecorderField(name: .pauseResume)
                }
                HStack {
                    Text("Pause between sentences")
                    Spacer()
                    Text("\(state.sentencePauseMS) ms")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                Slider(
                    value: Binding(
                        get: { Double(state.sentencePauseMS) },
                        set: { state.sentencePauseMS = Int($0.rounded()) }
                    ),
                    in: 0...800,
                    step: 50
                )
                Button("Reset Shortcuts to Defaults") {
                    state.resetShortcutsToDefaults()
                }
            }

            Section("ElevenLabs") {
                HStack {
                    SecureField(
                        maskedAPIKey ?? "Paste API key",
                        text: $apiKeyDraft
                    )
                    Button("Save") { saveKey() }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if maskedAPIKey != nil {
                        Button("Remove", role: .destructive) { removeKey() }
                    }
                }
                HStack(spacing: 12) {
                    if let apiKeyStatusMessage {
                        Text(apiKeyStatusMessage)
                            .font(.caption)
                            .foregroundStyle(apiKeyStatusIsError ? .red : .green)
                    } else if maskedAPIKey != nil {
                        Text("Stored in macOS Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Stored only in macOS Keychain. Scope to Text-to-Speech + User Read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if maskedAPIKey != nil {
                        Button(verifyingKey ? "Checking…" : "Verify Key") { verifyKey() }
                            .controlSize(.small)
                            .disabled(verifyingKey)
                    }
                }

                Picker("Audio quality", selection: $state.audioQuality) {
                    ForEach(ElevenLabsProvider.AudioQuality.allCases, id: \.self) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                Text("Both formats cost the same credits and use 44.1 kHz audio natively.")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Voice stability")
                        Spacer()
                        Text(state.voiceStability.formatted(.number.precision(.fractionLength(2))))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $state.voiceStability, in: 0.0...1.0, step: 0.05)
                    HStack {
                        Text("Voice similarity")
                        Spacer()
                        Text(state.voiceSimilarityBoost.formatted(.number.precision(.fractionLength(2))))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $state.voiceSimilarityBoost, in: 0.0...1.0, step: 0.05)
                    HStack {
                        Text("Higher stability yields steadier long-form narration.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Defaults") { state.resetVoiceSettingsToDefaults() }
                            .controlSize(.small)
                    }
                }
            }

            Section("Cost Controls") {
                LabeledContent("Daily budget") {
                    TextField("credits", value: $state.dailyBudget, format: .number)
                        .frame(width: 100)
                }
                LabeledContent("Confirm reads above") {
                    TextField("characters", value: $state.largeReadThreshold, format: .number)
                        .frame(width: 100)
                }
                HStack {
                    Text("Spent today: \(state.spentToday.formatted()) credits")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if state.budgetOverriddenToday {
                        Button("Re-enable Budget Today") { state.resetBudgetOverride() }
                            .controlSize(.small)
                    }
                }
            }

            Section("Privacy & Storage") {
                Toggle("Auto-delete ElevenLabs history", isOn: $state.autoDeleteHistory)
                Text("Removes cloud generations from your ElevenLabs history after synthesis.")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.historyStatus.isEmpty {
                    Text(state.historyStatus).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Cache audio for free replays", isOn: $state.cacheEnabled)
                Text("Turn off caching for sensitive reads. Existing audio stays until you purge it.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Audio cache: \(formattedBytes(state.cacheSizeBytes)) / 500 MB")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Purge Audio Cache") { state.purgeCache() }
                }
                HStack {
                    Text("Per-app routing rules (password managers blocked by default)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal rules.json") { state.revealRulesFile() }
                        .controlSize(.small)
                }
            }

            Section("Offline Voices") {
                LabeledContent("Model", value: "Kokoro v1.0 · 82M")
                LabeledContent("Runtime", value: "MLX Audio \(KokoroInstaller.mlxAudioVersion)")
                LabeledContent(
                    "Status",
                    value: state.kokoroInstalled
                        ? (state.kokoroDaemonRunning ? "Installed · Engine warm" : "Installed · Standby")
                        : (state.kokoroNeedsUpdate ? "Update required" : "Not installed")
                )
                Text("Includes Heart, Bella, Michael, and other English voices. Runs 100% locally on Apple Silicon.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if !state.kokoroInstalled {
                        Button(state.kokoroNeedsUpdate ? "Update Offline Voices" : "Install Offline Voices") {
                            state.installKokoro()
                        }
                        .disabled(state.kokoroInstallStatus != nil)
                    } else {
                        Button("Restart Offline Engine") { state.restartKokoroDaemon() }
                    }
                }
                if let status = state.kokoroInstallStatus {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 740)
        .onAppear {
            KeychainStore.invalidateCache()
            maskedAPIKey = KeychainStore.maskedAPIKey()
            state.refreshCacheSize()
            state.refreshKokoroDaemonStatus()
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

    private func saveKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard KeychainStore.saveAPIKey(trimmed) else {
            apiKeyStatusIsError = true
            apiKeyStatusMessage = "Keychain rejected the update. Unlock your login keychain and try again."
            return
        }
        apiKeyDraft = ""
        maskedAPIKey = KeychainStore.maskedAPIKey()
        apiKeyStatusIsError = false
        apiKeyStatusMessage = "Saved to Keychain"
        state.dismissError()
        state.refreshCredits()
        state.refreshVoices(force: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if apiKeyStatusMessage == "Saved to Keychain" {
                apiKeyStatusMessage = nil
            }
        }
    }

    private func removeKey() {
        _ = KeychainStore.deleteAPIKey()
        maskedAPIKey = nil
        apiKeyDraft = ""
        state.creditsRemaining = nil
        state.creditsLimit = nil
        apiKeyStatusIsError = false
        apiKeyStatusMessage = "API key removed"
    }

    private func verifyKey() {
        verifyingKey = true
        apiKeyStatusMessage = nil
        Task {
            KeychainStore.invalidateCache()
            do {
                let sub = try await ElevenLabsProvider().subscription()
                await MainActor.run {
                    verifyingKey = false
                    state.creditsRemaining = sub.remaining
                    state.creditsLimit = sub.characterLimit
                    apiKeyStatusIsError = false
                    apiKeyStatusMessage = "Valid key · \(sub.remaining.formatted()) credits remaining"
                }
            } catch {
                await MainActor.run {
                    verifyingKey = false
                    apiKeyStatusIsError = true
                    apiKeyStatusMessage = "Key check failed — verify your key and network."
                }
            }
        }
    }

    private func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
