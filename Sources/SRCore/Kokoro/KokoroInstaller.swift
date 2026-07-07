import CryptoKit
import Foundation

/// Installs the local Kokoro stack: uv-managed venv with a pinned
/// mlx-audio, the daemon script, and the model download with SHA-256
/// verification (P-12).
public struct KokoroInstaller: Sendable {
    // ── Supply-chain pins (P-12), resolved 2026-07-06 ──
    /// PyPI: latest mlx-audio at pin time.
    public static let mlxAudioVersion = "0.4.4"
    /// Python interpreter for the venv (uv downloads a standalone build
    /// if the system lacks it — deterministic across machines).
    public static let pythonVersion = "3.12"
    /// huggingface.co model repo + immutable revision (main @ pin time).
    public static let modelRepo = "mlx-community/Kokoro-82M-bf16"
    public static let modelRevision = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"
    /// SHA-256 of the files that define model behavior, at the pinned
    /// revision. Verified after download, recorded in manifest.json.
    public static let weightsFile = "kokoro-v1_0.safetensors"
    public static let weightsSHA256 =
        "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
    public static let configSHA256 =
        "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"

    public enum InstallProgress: Sendable {
        case creatingVenv
        case installingPackages
        case downloadingModel   // ~327 MB; huggingface_hub gives no byte callback here
        case verifying
        case done
        case failed(String)
    }

    public struct Manifest: Codable, Sendable {
        public let mlxAudioVersion: String
        public let modelRepo: String
        public let modelRevision: String
        public let weightsSHA256: String
        public let configSHA256: String
        public let snapshotPath: String
        public let installedAt: Date
    }

    public let paths: KokoroPaths

    public init(paths: KokoroPaths = .standard) {
        self.paths = paths
    }

    /// Installed = venv python + daemon script + verified manifest present.
    public var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: paths.venvPython.path)
            && fm.fileExists(atPath: paths.daemonScript.path)
            && (try? loadManifest()) != nil
    }

    public func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: paths.manifest)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Locate the uv binary (PATH, then the usual install locations).
    public static func findUV() -> URL? {
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/uv" }
        candidates += [
            NSHomeDirectory() + "/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Run the full install. `daemonSourceURL` is the sr_tts_server.py to
    /// copy in (from the app bundle's resources or the repo's daemon/ dir).
    public func install(daemonSourceURL: URL) -> AsyncStream<InstallProgress> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await runInstall(daemonSourceURL: daemonSourceURL) {
                        continuation.yield($0)
                    }
                    continuation.yield(.done)
                } catch {
                    let message = (error as? InstallError)?.message
                        ?? error.localizedDescription
                    SRLog.error("kokoro.install", ["error": message])
                    continuation.yield(.failed(message))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct InstallError: Error {
        let message: String
    }

    private func runInstall(
        daemonSourceURL: URL,
        progress: @Sendable (InstallProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.base, withIntermediateDirectories: true)

        guard let uv = Self.findUV() else {
            throw InstallError(message:
                "uv not found. Install it first: curl -LsSf https://astral.sh/uv/install.sh | sh")
        }

        // 1. venv (pinned interpreter; uv fetches a standalone build if needed)
        progress(.creatingVenv)
        try await run(uv, ["venv", "--python", Self.pythonVersion, paths.venvDir.path])

        // 2. pinned mlx-audio (brings mlx, numpy, huggingface_hub, misaki...)
        progress(.installingPackages)
        try await run(uv, [
            "pip", "install",
            "--python", paths.venvPython.path,
            "mlx-audio==\(Self.mlxAudioVersion)",
        ], timeout: 900)

        // 3. daemon script
        if fm.fileExists(atPath: paths.daemonScript.path) {
            try fm.removeItem(at: paths.daemonScript)
        }
        try fm.copyItem(at: daemonSourceURL, to: paths.daemonScript)

        // 4. model download at the pinned revision (huggingface.co — the
        // only network fetch, per the P-11 allowlist; explicit user action)
        progress(.downloadingModel)
        let snippet = """
        import os, sys
        os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
        from huggingface_hub import snapshot_download
        print(snapshot_download("\(Self.modelRepo)", revision="\(Self.modelRevision)"))
        """
        let snapshotPath = try await run(
            paths.venvPython, ["-c", snippet], timeout: 3600
        ).trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        guard !snapshotPath.isEmpty, fm.fileExists(atPath: snapshotPath) else {
            throw InstallError(message: "model download did not produce a snapshot path")
        }

        // 5. verify hashes (P-12)
        progress(.verifying)
        let snapshot = URL(fileURLWithPath: snapshotPath)
        let weightsHash = try Self.sha256(of: snapshot.appendingPathComponent(Self.weightsFile))
        guard weightsHash == Self.weightsSHA256 else {
            throw InstallError(message:
                "weights hash mismatch: expected \(Self.weightsSHA256), got \(weightsHash)")
        }
        let configHash = try Self.sha256(of: snapshot.appendingPathComponent("config.json"))
        guard configHash == Self.configSHA256 else {
            throw InstallError(message:
                "config hash mismatch: expected \(Self.configSHA256), got \(configHash)")
        }

        // 6. manifest
        let manifest = Manifest(
            mlxAudioVersion: Self.mlxAudioVersion,
            modelRepo: Self.modelRepo,
            modelRevision: Self.modelRevision,
            weightsSHA256: weightsHash,
            configSHA256: configHash,
            snapshotPath: snapshotPath,
            installedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: paths.manifest)
        SRLog.event("kokoro.installed", [
            "mlx_audio": Self.mlxAudioVersion,
            "revision": String(Self.modelRevision.prefix(12)),
        ])
    }

    /// Streaming SHA-256 (weights are ~327 MB — never load whole into RAM).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Run a subprocess, returning stdout. Throws with the stderr tail on
    /// failure (package-manager output — content-free by nature).
    @discardableResult
    private func run(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval = 300
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        try process.run()

        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        // Drain pipes off the calling task so big outputs can't deadlock.
        async let stdoutData = out.fileHandleForReading.readToEndAsync()
        async let stderrData = err.fileHandleForReading.readToEndAsync()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }

        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = String(data: await stderrData, encoding: .utf8) ?? ""
            throw InstallError(message:
                "\(executable.lastPathComponent) \(arguments.first ?? "") failed (exit \(process.terminationStatus)): \(stderr.suffix(400))")
        }
        return stdout
    }
}

extension FileHandle {
    /// Non-blocking full read for subprocess pipes.
    func readToEndAsync() async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: (try? self.readToEnd()) ?? Data())
            }
        }
    }
}
