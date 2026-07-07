import Foundation

// Source detection (normalize.py `_is_latex` / `_is_markdown`).
extension Normalizer {
    /// Score-based LaTeX detection with high-confidence guard + negative signals.
    static func isLatex(_ t: String) -> Bool {
        var score = 0
        var hasHigh = false
        // Negative: PDF ligature artifacts mean this is almost certainly not LaTeX source.
        if t.contains(where: { "\u{fb00}\u{fb01}\u{fb02}\u{fb03}\u{fb04}".contains($0) }) {
            score -= 5
        }
        // Negative: ATX headings are Markdown.
        if t.containsMatch(#"^#{1,6}\s"#, [.anchorsMatchLines]) { score -= 3 }
        // High-confidence signals.
        if t.containsMatch(#"\\(?:begin|end)\{"#) { score += 3; hasHigh = true }
        if t.containsMatch(#"\\\w+\{"#) { score += 2; hasHigh = true }
        if t.containsMatch(#"\$\$|\\\[|\\\("#) { score += 2; hasHigh = true }
        if t.containsMatch(#"(?<!\$)\$[^\$\n]+\$(?!\$)"#) { score += 2; hasHigh = true }
        if t.containsMatch(#"\\(?:frac|sum|int|prod|lim|sqrt|alpha|beta|gamma|delta|theta|lambda|mu|sigma|omega)\b"#) {
            score += 2; hasHigh = true
        }
        if t.containsMatch(#"\\(?:cite|ref|section)\{"#) { score += 2; hasHigh = true }
        if t.containsMatch(#"\\(?:item|itemize|enumerate)\b"#) { score += 2; hasHigh = true }
        // Low-confidence signals (only with at least one high-confidence).
        if hasHigh {
            if t.containsMatch(#"\\[a-zA-Z]+"#) { score += 1 }
            if t.containsMatch(#"^\s*%"#, [.anchorsMatchLines]) { score += 1 }
        }
        return score >= 3
    }

    /// Score-based Markdown detection with high-confidence guard.
    static func isMarkdown(_ t: String) -> Bool {
        var score = 0
        var hasHigh = false
        if t.containsMatch(#"^```"#, [.anchorsMatchLines]) { score += 3; hasHigh = true }
        if t.containsMatch(#"^#{1,6}\s"#, [.anchorsMatchLines]) { score += 2; hasHigh = true }
        if t.containsMatch(#"\*\*[^*]+\*\*"#) { score += 2; hasHigh = true }
        if t.containsMatch(#"\[[^\]]+\]\([^)]+\)"#) { score += 2; hasHigh = true }
        if t.containsMatch(#"!\[[^\]]*\]\([^)]+\)"#) { score += 2; hasHigh = true }
        if t.containsMatch(#"\[\[[^\]]+\]\]"#) { score += 2; hasHigh = true }
        if t.containsMatch(#"\A---\s*\n"#) { score += 2; hasHigh = true }
        if hasHigh {
            if t.containsMatch(#"^[-*+]\s"#, [.anchorsMatchLines]) { score += 1 }
            if t.containsMatch(#"^\d+\.\s"#, [.anchorsMatchLines]) { score += 1 }
            if t.containsMatch(#"^>\s"#, [.anchorsMatchLines]) { score += 1 }
            if t.containsMatch(#"^---\s*$"#, [.anchorsMatchLines]) { score += 1 }
            if t.containsMatch(#"`[^`]+`"#) { score += 1 }
        }
        return score >= 3
    }
}
