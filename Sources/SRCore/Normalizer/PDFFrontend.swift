import Foundation

// PDF front-end (normalize.py `_frontend_pdf`).
// Deviation: no ftfy mojibake repair (see Normalizer.swift header).
extension Normalizer {
    static func frontendPDF(_ input: String) -> String {
        var t = input
        // Line endings: CRLF and stray CR to LF.
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r", with: "\n")
        // Invisible characters: zero-width, soft hyphens, PUA (math font garbage).
        t = t.sub("[\u{200b}\u{200c}\u{200d}\u{feff}\u{00ad}]", "")
        t = t.sub("[\u{e000}-\u{f8ff}]", "")
        // Ligatures from PDF fonts: ff/ffi/ffl before fi/fl to avoid partial match.
        t = t.replacingOccurrences(of: "\u{fb00}", with: "ff")
        t = t.replacingOccurrences(of: "\u{fb03}", with: "ffi")
        t = t.replacingOccurrences(of: "\u{fb04}", with: "ffl")
        t = t.replacingOccurrences(of: "\u{fb01}", with: "fi")
        t = t.replacingOccurrences(of: "\u{fb02}", with: "fl")
        // Unicode subscript digits to regular digits (H₂O -> H2O).
        t = t.sub("[\u{2080}-\u{2089}]") { m in
            let scalar = m.matched.unicodeScalars.first!
            return String(UnicodeScalar(scalar.value - 0x2050)!)
        }
        // Unicode fractions to words.
        for (frac, word) in NormalizerData.fractions {
            t = t.replacingOccurrences(of: frac, with: " " + word + " ")
        }
        // Strip trailing whitespace on each line.
        t = t.sub(#"[ \t]+$"#, "", [.anchorsMatchLines])
        // Rejoin hyphenated word splits at line ends (preserve compound hyphens).
        t = t.sub(#"(\S+)-\n(\w+)"#) { m in
            let left = m[1] ?? ""
            let right = m[2] ?? ""
            if left.contains("-") { return left + "-" + right }
            if NormalizerData.compoundPrefixes.contains(left.lowercased()) {
                return left + "-" + right
            }
            return left + right
        }
        // Protect paragraph breaks (2+ newlines), rejoin the rest.
        t = t.sub(#"\n{2,}"#, "\u{00}")
        t = t.sub("(?<![.!?:\"'])\\n", " ")
        t = t.replacingOccurrences(of: "\u{00}", with: "\n\n")
        // Superscript citations copied from PDF with a space: "estimates 2 ." → "estimates."
        t = t.sub(#"(?<=[a-z]) (\d{1,3}(?:\s*,\s*\d{1,3})*)(?= [.,;:?!])"#, "")
        // Glued superscript citations: forests11. → forests.
        t = t.sub(#"(?<=[a-z]{4})\d{2,3}(?=[.,;:?!)\]\s]|$)"#, "")
        // Post-period superscript citations: automation.1,2 The → automation. The
        t = t.sub("(?<=[a-z]{4})\\.\\d{1,3}(?:\\s*[,\u{2013}\u{2014}-]\\s*\\d{1,3})*(?=\\s+[A-Z])", ".")
        // Scientific notation: 1.5 x 10^-3 spoken as full phrase.
        let sci: (RxMatch) -> String = { m in
            let raw = m[2] ?? ""
            let sign = raw.contains("\u{207b}") ? "-" : (raw.hasPrefix("-") ? "-" : "")
            let d = supToDigits(raw
                .replacingOccurrences(of: "\u{207b}", with: "")
                .replacingOccurrences(of: "-", with: ""))
            guard let e = Int(sign + d) else { return m.matched }
            let p = (m[1] ?? "").isEmpty ? "" : (m[1] ?? "") + " times "
            return p + "10 to the " + (e < 0 ? "negative " : "") + String(abs(e))
        }
        t = t.sub("(?:(\\d[\\d.,]*)\\s*[\u{00d7}xX]\\s*)?10([\u{207b}\u{00b9}\u{00b2}\u{00b3}\u{2074}-\u{2079}\u{2070}]+)", sci)
        t = t.sub("(?:(\\d[\\d.,]*)\\s*[\u{00d7}xX]\\s*)?10\\^(-?\\d+)", sci)
        // Isotope notation: superscript digits before element symbol.
        t = t.sub("(?<!\\w)(" + NormalizerData.supRe + ")([A-Z][a-z]?)\\b") { m in
            let mass = supToDigits(m[1] ?? "")
            let sym = m[2] ?? ""
            return (NormalizerData.elements[sym] ?? sym) + "-" + mass
        }
        // Superscript minus+digit (cm⁻¹ -> inverse, cm⁻² -> to the negative 2).
        t = t.sub("\u{207b}[\u{00b9}\u{00b2}\u{00b3}\u{2074}-\u{2079}\u{2070}]+") { m in
            let digits = supToDigits(String(m.matched.dropFirst()))
            let n = Int(digits) ?? 1
            let sp = m.start > 0 ? " " : ""
            if n == 1 { return sp + "inverse" }
            return sp + "to the negative " + String(n)
        }
        // Remaining superscript digits -> spoken exponents.
        t = t.sub(NormalizerData.supRe) { m in
            let n = Int(supToDigits(m.matched)) ?? 0
            if n == 2 { return " squared " }
            if n == 3 { return " cubed " }
            return " to the " + String(n) + " "
        }
        // Uncertainty notation: 2.5179(4) -> 2.5179.
        t = t.sub(#"(\d\.\d+)\(\d+\)"#, "$1")
        // Bullet and list markers at line start.
        t = t.sub("^[\u{2022}\u{2023}\u{25e6}\u{2043}\u{2219}] +", "", [.anchorsMatchLines])
        t = t.sub(#"^- +"#, "", [.anchorsMatchLines])
        t = t.sub(#"^\d+[.)]\s+"#, "", [.anchorsMatchLines])
        return t
    }
}
