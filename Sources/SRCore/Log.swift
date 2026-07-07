import Foundation
import os

/// Content-free logging (P-5).
///
/// Records only: timestamps, provider, model, character counts, cache
/// hit/miss, latency, HTTP status. Never the text being spoken, never
/// paths that embed text. Backed by os.Logger (unified logging) plus a
/// rotating plain-text file at ~/Library/Logs/sr/sr.log for greppability.
public enum SRLog {
    private static let logger = Logger(subsystem: "com.patrickellis.sr", category: "sr")
    private static let queue = DispatchQueue(label: "com.patrickellis.sr.log", qos: .utility)

    public static var logFileURL: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/sr/sr.log")
    }

    /// Log an event. `fields` must be content-free by construction:
    /// callers pass counts and identifiers, never captured text.
    public static func event(_ name: StaticString, _ fields: [String: String] = [:]) {
        let joined = fields.isEmpty ? "" : " " + fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.info("\(name, privacy: .public)\(joined, privacy: .public)")
        appendToFile("\(name)\(joined)")
    }

    public static func error(_ name: StaticString, _ fields: [String: String] = [:]) {
        let joined = fields.isEmpty ? "" : " " + fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.error("\(name, privacy: .public)\(joined, privacy: .public)")
        appendToFile("ERROR \(name)\(joined)")
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func appendToFile(_ line: String) {
        queue.async {
            let url = logFileURL
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            // Rotate at 5 MB by RENAME, not delete: deleting strands another
            // process's open handle on an unlinked inode, silently dropping
            // its writes. Rename keeps that handle valid (it writes into the
            // rotated file) while this process starts a fresh one.
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > 5_000_000 {
                let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
            }
            let entry = "\(stamp.string(from: Date())) \(line)\n"
            // O_APPEND: GUI and CLI share this file; seekToEnd+write from two
            // processes interleaves at the same offset and loses lines.
            // Kernel-atomic appends don't.
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try? handle.write(contentsOf: Data(entry.utf8))
            try? handle.close()
        }
    }
}
