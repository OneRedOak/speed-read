import Foundation

// TEMPORARY STUBS — replaced by the full normalize.py port (task #4).
extension Normalizer {
    static func isLatex(_ t: String) -> Bool { false }
    static func isMarkdown(_ t: String) -> Bool { false }
    static func frontendLatex(_ t: String) -> String { t }
    static func frontendMarkdown(_ t: String) -> String { t }
    static func frontendPDF(_ t: String) -> String { t }
    static func phase0(_ t: String) -> String { t }
    static func phaseA(_ t: String) -> String { t }
    static func phaseB(_ t: String) -> String { t }
    static func phaseC(_ t: String) -> String { t }
    static func phaseD(_ t: String) -> String { t.trimmingCharacters(in: .whitespacesAndNewlines) }
}
