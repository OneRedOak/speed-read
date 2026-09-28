import AppKit
import Foundation
import SRCore
import SwiftUI
import Testing
@testable import sr

/// Optional native layout artifacts: SR_RENDER_UI=1 make test.
/// Uses an isolated preference suite; no speech, network, or permission prompts.
@Suite @MainActor struct ReaderLayoutTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SR_RENDER_UI"] == "1"))
    func renderReaderModes() throws {
        let suite = "sr-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(store: SettingsStore(defaults: defaults), startServices: false)
        state.kokoroInstalled = true
        state.kokoroNeedsUpdate = false
        state.localVoiceID = "af_heart"
        state.playbackRate = 1.25
        state.creditsRemaining = 22000
        state.creditsLimit = 176000
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SR_UI_OUTPUT"] ?? "/tmp/sr-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in SettingsStore.BackendMode.allCases {
            state.backendMode = mode
            for dark in [true, false] {
                try render(state, dark: dark, url: directory.appendingPathComponent("\(mode.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        state.backendMode = .cloud
        state.availableVoices = [Voice(id: "layout-voice", name: "Chris — Charming, Down-to-Earth")]
        state.voiceID = "layout-voice"
        state.playback.startSession(totalSentences: 27)
        state.playback.pause()
        defer { state.playback.stop() }
        try render(state, dark: true, url: directory.appendingPathComponent("paused-dark.png"))
    }

    private func render(_ state: AppState, dark: Bool, url: URL) throws {
        let view = MenuView().environmentObject(state)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        #expect(size.width == 380)
        #expect(size.height < 800)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
