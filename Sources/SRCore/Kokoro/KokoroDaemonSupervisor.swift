import Foundation
import Security

/// Supervises the Kokoro daemon process (P-9).
///
/// Spawns the venv Python running sr_tts_server.py --managed with a fresh
/// per-launch auth token, waits for the Unix socket to appear (cold model
/// load can take tens of seconds), and restarts with exponential backoff
/// (1 s → 30 s cap, reset after 60 s healthy).
public actor KokoroDaemonSupervisor {
    public let paths: KokoroPaths

    private var process: Process?
    private(set) public var token: String = ""
    private var consecutiveFailures = 0
    private var lastSpawnAttempt: Date?
    private var healthySince: Date?

    public init(paths: KokoroPaths = .standard) {
        self.paths = paths
    }

    public var socketPath: String { paths.socketPath }

    public enum SupervisorError: Error {
        case notInstalled
        case spawnFailed(String)
        case startupTimeout
        case backingOff(retryAfter: TimeInterval)
    }

    /// Ensure a healthy daemon is running. Returns when the socket is
    /// connectable. Throws SupervisorError on failure.
    public func ensureRunning() async throws {
        // Already healthy? Accept a connectable socket even when we didn't
        // spawn the daemon (another sr process — GUI vs CLI — owns it; the
        // shared token file makes it usable, and the flock guard would make
        // our own spawn exit immediately anyway).
        if Self.socketConnectable(paths.socketPath) {
            if let since = healthySince, Date().timeIntervalSince(since) > 60 {
                consecutiveFailures = 0  // stable — reset backoff
            }
            if healthySince == nil { healthySince = Date() }
            return
        }
        healthySince = nil

        // Actors are reentrant: while one caller awaits inside spawn(), a
        // concurrent synthesize would re-enter here, see no socket, and
        // spawn a second daemon over the first. Share one startup task.
        if let inFlight = startupTask {
            try await inFlight.value
            return
        }

        guard KokoroInstaller(paths: paths).isInstalled else {
            throw SupervisorError.notInstalled
        }

        let task = Task { [self] in
            // Exponential backoff between spawn attempts.
            if let last = lastSpawnAttempt {
                let delay = min(pow(2.0, Double(consecutiveFailures)), 30.0)
                let elapsed = Date().timeIntervalSince(last)
                if consecutiveFailures > 0 && elapsed < delay {
                    try await Task.sleep(for: .seconds(delay - elapsed))
                }
            }
            try await spawn()
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private var startupTask: Task<Void, Error>?

    private func spawn() async throws {
        stopProcess()

        lastSpawnAttempt = Date()
        token = Self.generateToken()

        // Persist for other sr processes (0600, same trust domain as the
        // socket). Written before launch so no request can race it.
        try? FileManager.default.createDirectory(at: paths.base,
                                                 withIntermediateDirectories: true)
        try? Data(token.utf8).write(to: paths.tokenFile, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: paths.tokenFile.path)

        let p = Process()
        p.executableURL = paths.venvPython
        p.arguments = [paths.daemonScript.path, "--managed"]
        p.environment = ProcessInfo.processInfo.environment.merging(
            ["SR_DAEMON_TOKEN": token]) { _, new in new }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            consecutiveFailures += 1
            throw SupervisorError.spawnFailed(String(describing: error))
        }
        process = p
        SRLog.event("kokoro.daemon_spawn", ["pid": String(p.processIdentifier)])

        // Wait for the socket (cold start loads the model: allow 60 s).
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if Self.socketConnectable(paths.socketPath) {
                consecutiveFailures = 0
                healthySince = Date()
                SRLog.event("kokoro.daemon_ready", [:])
                return
            }
            if !p.isRunning {
                // Exited during startup — either flock conflict (another
                // daemon we don't own the token for) or a real failure.
                // Either way our token isn't accepted: kill any stranger
                // socket owner is not possible; count as failure.
                consecutiveFailures += 1
                throw SupervisorError.spawnFailed(
                    "daemon exited during startup (status \(p.terminationStatus))")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        consecutiveFailures += 1
        stopProcess()
        throw SupervisorError.startupTimeout
    }

    public func stop() {
        stopProcess()
        healthySince = nil
    }

    private func stopProcess() {
        if let p = process, p.isRunning {
            p.terminate()  // SIGTERM → daemon cleans up socket/pid and exits
        }
        process = nil
    }

    // MARK: - Static helpers (also used by tests)

    /// 32 random bytes as 64 hex chars.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SystemRandomNumberGenerator is also cryptographically secure.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Health check: can we connect to the Unix socket right now?
    public static func socketConnectable(_ path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        guard ok else { return false }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        return result == 0
    }
}
