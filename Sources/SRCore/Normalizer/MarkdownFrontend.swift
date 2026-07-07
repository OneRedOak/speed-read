import Foundation

// Markdown front-end (normalize.py `_frontend_markdown`, rules M1-M10).
extension Normalizer {
    static func frontendMarkdown(_ input: String) -> String {
        var t = input

        // ── M1: YAML frontmatter + Obsidian comments ──
        t = t.sub(#"\A---\s*\n.*?\n---\s*\n"#, "", [.dotMatchesLineSeparators])
        t = t.sub(#"%%.*?%%"#, "", [.dotMatchesLineSeparators])

        // ── M2: Code blocks (fenced only) ──
        t = t.sub(#"^```[^\n]*\n.*?\n```"#, "Code block omitted.",
                  [.anchorsMatchLines, .dotMatchesLineSeparators])

        // ── M3: Headings ──
        t = t.sub(#"^#\s+(.*?)$"#, "Title: $1.", [.anchorsMatchLines])
        t = t.sub(#"^##\s+(.*?)$"#, "Section: $1.", [.anchorsMatchLines])
        t = t.sub(#"^###\s+(.*?)$"#, "Subsection: $1.", [.anchorsMatchLines])
        t = t.sub(#"^#{4,6}\s+(.*?)$"#, "$1.", [.anchorsMatchLines])

        // ── M4: Images (standard + Obsidian wikilink) ──
        t = t.sub(#"!\[([^\]]+)\]\([^)]+\)"#, "Image: $1.")
        t = t.sub(#"!\[\]\([^)]+\)"#, "Image.")
        t = t.sub(#"!\[\[([^\]]+)\]\]"#, "Image.")

        // ── M5: Links + wikilinks ──
        t = t.sub(#"\[([^\]]+)\]\([^)]+\)"#, "$1")
        t = t.sub(#"\[\[([^|\]]+)\|([^\]]+)\]\]"#, "$2")   // [[target|alias]]
        t = t.sub(#"\[\[([^\]]+)\]\]"#, "$1")              // [[target]]

        // ── M6: Text formatting ──
        t = t.sub(#"\*\*([^\n]+?)\*\*"#, "$1")             // bold (allows nested *italic*)
        t = t.sub(#"__([^\n]+?)__"#, "$1")                 // bold (underscores)
        t = t.sub(#"\*([^ *\n][^*\n]*)\*"#, "$1")          // italic (space after * = list marker)
        t = t.sub(#"(?<!\w)_([^_\n]+)_(?!\w)"#, "$1")      // italic (underscores)
        t = t.sub(#"~~([^~]+)~~"#, "$1")                   // strikethrough
        t = t.sub(#"`([^`]+)`"#) { m in                     // inline code (strip $ to prevent M7 math)
            (m[1] ?? "").replacingOccurrences(of: "$", with: "")
        }

        // ── M6b: Footnotes and tags ──
        t = t.sub(#"^\[\^[^\]]+\]:\s*(.*)"#, "(footnote: $1)", [.anchorsMatchLines])
        t = t.sub(#"\[\^[^\]]+\]"#, "")
        t = t.sub(#"(?<=\s)#[a-zA-Z][\w/-]*"#, "")

        // ── M7: Math (reuse MathSpeech) ──
        t = t.sub(#"\$\$(.*?)\$\$"#, options: [.dotMatchesLineSeparators]) { m in
            " The equation: " + MathSpeech.mathToSpeech(m[1] ?? "") + "."
        }
        t = t.sub(#"\$([^\$\n]+)\$"#) { m in
            " " + MathSpeech.mathToSpeech(m[1] ?? "") + " "
        }

        // ── M8: Block elements ──
        // GFM tables (header + separator + rows).
        t = t.sub(#"(?:^\|[^\n]+\|\s*\n){2,}"#, "Table omitted.\n", [.anchorsMatchLines])
        // Obsidian callouts: > [!note] Title\n> content → "Note: Title. content"
        t = t.sub(#"^>\s*\[!(\w+)\][ \t]*(.*)\n((?:^>.*\n?)*)"#,
                  options: [.anchorsMatchLines]) { m in
            let ctype = pyCapitalize(m[1] ?? "")
            let title = (m[2] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyLines = (m[3] ?? "").isEmpty ? [] : (m[3] ?? "").components(separatedBy: "\n")
            let body = bodyLines
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { line in
                    String(line.drop(while: { $0 == ">" }))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .joined(separator: " ")
            var result = title.isEmpty ? ctype + "." : ctype + ": " + title + "."
            if !body.isEmpty { result += " " + body }
            return result
        }
        // Blockquotes (after callouts).
        t = t.sub(#"(?:^>\s?[^\n]*\n?)+"#, options: [.anchorsMatchLines]) { m in
            let lines = m.matched.components(separatedBy: "\n")
            let text = lines
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { line in
                    String(line.drop(while: { $0 == ">" }))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .joined(separator: " ")
            return "Quote: " + text
        }
        // Unordered lists.
        t = t.sub(#"(?:^[-*+]\s+[^\n]+\n?)+"#, options: [.anchorsMatchLines]) { m in
            m.matched.allMatches(#"^[-*+]\s+(.*)"#, [.anchorsMatchLines])
                .map { $0[1] ?? "" }
                .joined(separator: " ")
        }
        // Ordered lists.
        t = t.sub(#"(?:^\d+\.\s+[^\n]+\n?)+"#, options: [.anchorsMatchLines]) { m in
            m.matched.allMatches(#"^\d+\.\s+(.*)"#, [.anchorsMatchLines])
                .map { $0[1] ?? "" }
                .enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: " ")
        }
        // Horizontal rules.
        t = t.sub(#"^(?:---|\*\*\*|___)\s*$"#, "", [.anchorsMatchLines])

        // ── M9: HTML tags stripped ──
        t = t.sub(#"<[^>]+>"#, "")

        // ── M10: Cleanup (preserve paragraph breaks) ──
        t = t.sub(#"\n{2,}"#, "\u{00}")
        t = t.sub(#"\n"#, " ")
        t = t.replacingOccurrences(of: "\u{00}", with: "\n\n")
        return t
    }
}
