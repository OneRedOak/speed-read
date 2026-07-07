import Foundation

/// Filesystem layout for the local Kokoro stack (P-9).
///
/// Everything lives under ~/Library/Application Support/sr/kokoro/:
///   venv/          — uv-managed Python environment (pinned mlx-audio)
///   sr_tts_server.py — daemon script, copied at install time
///   daemon.sock    — Unix domain socket (0600), created by the daemon
///   manifest.json  — install manifest (pins + verified hashes)
///   tmp/gen_*/     — per-request WAV output (client deletes after read)
public struct KokoroPaths: Sendable {
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    public static let standard = KokoroPaths(
        base: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sr/kokoro", isDirectory: true)
    )

    public var venvDir: URL { base.appendingPathComponent("venv", isDirectory: true) }
    public var venvPython: URL { venvDir.appendingPathComponent("bin/python3") }
    public var daemonScript: URL { base.appendingPathComponent("sr_tts_server.py") }
    public var socketPath: String { base.appendingPathComponent("daemon.sock").path }
    public var manifest: URL { base.appendingPathComponent("manifest.json") }
    public var tmpRoot: URL { base.appendingPathComponent("tmp", isDirectory: true) }
}
