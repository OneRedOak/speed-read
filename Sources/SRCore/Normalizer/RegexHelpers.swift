import Foundation

// Python-`re`-like helpers over NSRegularExpression (ICU), so the
// normalize.py port stays line-for-line auditable against the reference.
//
// Flag mapping: re.MULTILINE → .anchorsMatchLines,
//               re.DOTALL   → .dotMatchesLineSeparators,
//               re.IGNORECASE → .caseInsensitive.
// Template mapping: Python \1 → ICU $1.

final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression {
        let key = "\(options.rawValue)\u{1F}\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let re = cache[key] { return re }
        // Patterns are ported literals — a failure to compile is a port bug.
        let re = try! NSRegularExpression(pattern: pattern, options: options)
        cache[key] = re
        return re
    }
}

/// Python `m` (match object) analogue for closure-based replacement.
struct RxMatch {
    let result: NSTextCheckingResult
    let source: String

    /// Group text, nil when the group did not participate (Python None).
    subscript(_ i: Int) -> String? {
        guard i < result.numberOfRanges else { return nil }
        let r = result.range(at: i)
        guard r.location != NSNotFound, let range = Range(r, in: source) else { return nil }
        return String(source[range])
    }

    /// Whole match (Python m.group(0)).
    var matched: String { self[0] ?? "" }

    /// UTF-16 offset of match start (Python m.start()).
    var start: Int { result.range.location }
}

extension String {
    /// re.sub with a string template ($1-style group refs).
    func sub(_ pattern: String, _ template: String,
             _ options: NSRegularExpression.Options = []) -> String {
        let re = RegexCache.shared.regex(pattern, options)
        let ns = self as NSString
        return re.stringByReplacingMatches(
            in: self, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    /// re.sub with a callable replacement (result inserted literally).
    func sub(_ pattern: String, options: NSRegularExpression.Options = [],
             _ replacer: (RxMatch) -> String) -> String {
        let re = RegexCache.shared.regex(pattern, options)
        let ns = self as NSString
        let matches = re.matches(in: self, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return self }
        var out = ""
        out.reserveCapacity(count + 16)
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += replacer(RxMatch(result: m, source: self))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// re.finditer.
    func allMatches(_ pattern: String,
                    _ options: NSRegularExpression.Options = []) -> [RxMatch] {
        let re = RegexCache.shared.regex(pattern, options)
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length))
            .map { RxMatch(result: $0, source: self) }
    }

    /// re.search != None.
    func containsMatch(_ pattern: String,
                       _ options: NSRegularExpression.Options = []) -> Bool {
        firstMatch(pattern, options) != nil
    }

    /// re.search.
    func firstMatch(_ pattern: String,
                    _ options: NSRegularExpression.Options = []) -> RxMatch? {
        let re = RegexCache.shared.regex(pattern, options)
        let ns = self as NSString
        return re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length))
            .map { RxMatch(result: $0, source: self) }
    }

    /// re.split.
    func splitRegex(_ pattern: String,
                    _ options: NSRegularExpression.Options = []) -> [String] {
        let re = RegexCache.shared.regex(pattern, options)
        let ns = self as NSString
        var parts: [String] = []
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }
}

/// Stable length-descending sort for regex alternations, mirroring Python's
/// stable `sorted(..., key=len, reverse=True)`.
func lengthDescending(_ items: [String]) -> [String] {
    items.enumerated()
        .sorted { ($0.element.count, $1.offset) > ($1.element.count, $0.offset) }
        .map(\.element)
}

/// Python str.capitalize(): first scalar uppercased, remainder lowercased.
func pyCapitalize(_ s: String) -> String {
    guard let first = s.first else { return s }
    return String(first).uppercased() + s.dropFirst().lowercased()
}

/// Translate superscript digits ¹²³⁴⁵⁶⁷⁸⁹⁰ to ASCII digits (Python _SD table).
func supToDigits(_ s: String) -> String {
    String(s.map { NormalizerData.superscriptDigits[$0] ?? $0 })
}
