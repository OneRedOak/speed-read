import AppKit
import Foundation
import SRCore

/// Headless CLI modes (acceptance testing + Phase 4 CLI seed).
///
///   sr --install-kokoro          install the local voice, print progress
///   sr --speak <file|->          speak a file (or stdin) through the full
///                                pipeline: normalize → chunk → synthesize
///                                (cache, janitor, fallback) → play
///   sr --speak-clipboard         speak the clipboard (honors concealed-
///                                content refusal; exit 2 when refused)
///
/// Flags: --local forces the Kokoro route.
@MainActor
enum HeadlessCLI {
    enum Mode {
        case installKokoro
        case speak(source: String, forceLocal: Bool)
        case speakClipboard(forceLocal: Bool)

        init?(arguments: [String]) {
            let args = Array(arguments.dropFirst())
            guard !args.isEmpty else { return nil }
            let forceLocal = args.contains("--local")
            if args.contains("--install-kokoro") {
                self = .installKokoro
            } else if let i = args.firstIndex(of: "--speak"), i + 1 < args.count {
                self = .speak(source: args[i + 1], forceLocal: forceLocal)
            } else if args.contains("--speak-clipboard") {
                self = .speakClipboard(forceLocal: forceLocal)
            } else {
                return nil
            }
        }
    }

    static func run(_ mode: Mode) async -> Int32 {
        switch mode {
        case .installKokoro:
            return await installKokoro()
        case .speak(let source, let forceLocal):
            guard let text = readText(source) else {
                FileHandle.standardError.write(Data("cannot read \(source)\n".utf8))
                return 1
            }
            return await speak(text, forceLocal: forceLocal)
        case .speakClipboard(let forceLocal):
            switch SelectionCapture.clipboardText() {
            case .concealed:
                print("CONCEALED-REFUSED")
                return 2
            case .empty, .accessibilityDenied:
                print("clipboard empty")
                return 1
            case .text(let text, _):
                return await speak(text, forceLocal: forceLocal)
            }
        }
    }

    private static func readText(_ source: String) -> String? {
        if source == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }
        return try? String(contentsOfFile: source, encoding: .utf8)
    }

    // MARK: - Install

    private static func installKokoro() async -> Int32 {
        guard let source = daemonScriptSource() else {
            print("daemon script not found (looked in bundle + ./daemon/)")
            return 1
        }
        if KokoroRuntime.shared.isInstalled {
            print("already installed")
            return 0
        }
        for await progress in KokoroRuntime.shared.installer.install(daemonSourceURL: source) {
            switch progress {
            case .creatingVenv: print("[1/4] creating Python venv…")
            case .installingPackages: print("[2/4] installing pinned mlx-audio…")
            case .downloadingModel: print("[3/4] downloading Kokoro model (~330 MB)…")
            case .verifying: print("[4/4] verifying SHA-256…")
            case .done:
                print("done — local voice installed")
                return 0
            case .failed(let message):
                print("FAILED: \(message)")
                return 1
            }
        }
        print("FAILED: install stream ended unexpectedly")
        return 1
    }

    private static func daemonScriptSource() -> URL? {
        if let bundled = Bundle.main.url(forResource: "sr_tts_server", withExtension: "py") {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("daemon/sr_tts_server.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // MARK: - Speak

    private static func speak(_ text: String, forceLocal: Bool) async -> Int32 {
        let settings = SettingsStore()
        let normalized = Normalizer.normalize(text)
        let chunks = Chunker.split(normalized)
        guard !chunks.isEmpty else {
            print("nothing to speak")
            return 1
        }
        print("sentences=\(chunks.count) chars=\(normalized.count)")

        AudioCache.shared.enabled = settings.cacheEnabled
        let playback = PlaybackEngine(rate: settings.playbackRate,
                                      sentencePauseMS: settings.sentencePauseMS)
        let pipeline = SynthesisPipeline()
        let janitor = HistoryJanitor()
        let ledger = CostLedger()
        let deleteHistory = settings.autoDeleteHistory

        let cloud = SynthesisPipeline.Route(
            provider: ElevenLabsProvider(modelID: settings.modelID),
            voiceID: settings.voiceID, modelID: settings.modelID)
        let local: SynthesisPipeline.Route? = KokoroRuntime.shared.isInstalled
            ? SynthesisPipeline.Route(provider: KokoroProvider(),
                                      voiceID: settings.localVoiceID, modelID: "kokoro-82M")
            : nil

        if forceLocal && local == nil {
            print("local voice not installed")
            return 1
        }
        let primary = forceLocal ? local! : cloud
        let fallback = forceLocal ? nil : local

        final class ExitBox: @unchecked Sendable {
            var code: Int32 = 0
            var resumed = false
        }
        let box = ExitBox()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @MainActor (Int32) -> Void = { code in
                guard !box.resumed else { return }
                box.resumed = true
                box.code = code
                continuation.resume()
            }

            playback.startSession(totalSentences: chunks.count)
            playback.onFinished = { finish(0) }

            pipeline.run(
                chunks: chunks,
                primary: primary,
                fallback: fallback,
                settings: settings.voiceSettings,
                cache: settings.cacheEnabled ? AudioCache.shared : nil,
                callbacks: .init(
                    deliver: { index, audio in playback.feed(index: index, audio: audio) },
                    billed: { billed in ledger.record(billedCharacters: billed) },
                    historyID: { id in
                        guard deleteHistory else { return }
                        Task { await janitor.enqueue(id) }
                    },
                    fellBack: { print("FELL-BACK-TO-LOCAL") },
                    failed: { error in
                        print("SYNTHESIS-FAILED: \(error)")
                        playback.stop()
                        finish(3)
                    }
                )
            )
        }

        // Do not exit with history deletions pending: the janitor's
        // 404-retry ladder (2.5s + 6s + 20s) exists precisely because
        // ElevenLabs materializes history items late. 45s covers it.
        if deleteHistory {
            let drained = await janitor.waitUntilDrained(timeout: 45)
            let janitorStatus = await janitor.statusLine
            if drained {
                print(janitorStatus)
            } else {
                print("WARNING: exiting with history deletions pending — \(janitorStatus)")
                if box.code == 0 { box.code = 4 }
            }
        }
        await KokoroRuntime.shared.supervisor.stop()
        return box.code
    }
}
