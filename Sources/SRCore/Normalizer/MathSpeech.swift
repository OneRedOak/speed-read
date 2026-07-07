import Foundation

/// LaTeX math → spoken English (normalize.py `_math_to_speech` and helpers).
enum MathSpeech {
    // _GREEK_TEX (var* forms first, mirroring reference insertion order).
    static let greekTexOrder: [String] = [
        "varepsilon", "vartheta", "varpi", "varrho", "varsigma", "varphi",
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma",
        "tau", "upsilon", "phi", "chi", "psi", "omega",
        "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon",
        "Phi", "Psi", "Omega",
    ]
    static let greekTex: [String: String] = [
        "varepsilon": "epsilon", "vartheta": "theta", "varpi": "pi", "varrho": "rho",
        "varsigma": "sigma", "varphi": "phi",
        "alpha": "alpha", "beta": "beta", "gamma": "gamma", "delta": "delta",
        "epsilon": "epsilon", "zeta": "zeta", "eta": "eta", "theta": "theta",
        "iota": "iota", "kappa": "kappa", "lambda": "lambda", "mu": "mu",
        "nu": "nu", "xi": "xi", "pi": "pi", "rho": "rho", "sigma": "sigma",
        "tau": "tau", "upsilon": "upsilon", "phi": "phi", "chi": "chi",
        "psi": "psi", "omega": "omega",
        "Gamma": "Gamma", "Delta": "Delta", "Theta": "Theta", "Lambda": "Lambda",
        "Xi": "Xi", "Pi": "Pi", "Sigma": "Sigma", "Upsilon": "Upsilon",
        "Phi": "Phi", "Psi": "Psi", "Omega": "Omega",
    ]
    static let greekTexPattern: String =
        "\\\\(" + lengthDescending(greekTexOrder).joined(separator: "|") + ")(?![a-zA-Z])"

    // _MATH_SYM
    static let mathSymOrder: [String] = [
        "hbar", "nabla", "partial", "infty", "pm", "mp", "times", "cdot", "cdots",
        "ldots", "vdots", "ddots", "leq", "geq", "le", "ge", "neq", "ne",
        "approx", "sim", "simeq", "equiv", "propto", "in", "notin", "subset",
        "supset", "subseteq", "supseteq", "cup", "cap", "setminus", "emptyset",
        "varnothing", "forall", "exists", "nexists", "neg", "lnot", "land", "lor",
        "rightarrow", "leftarrow", "leftrightarrow", "Rightarrow", "Leftarrow",
        "Leftrightarrow", "iff", "mapsto", "to", "gets", "uparrow", "downarrow",
        "oplus", "otimes", "wedge", "vee", "perp", "parallel", "angle", "triangle",
        "therefore", "because", "dagger", "ddagger", "ell", "Re", "Im",
    ]
    static let mathSym: [String: String] = [
        "hbar": "h-bar", "nabla": "del", "partial": "partial",
        "infty": "infinity", "pm": "plus or minus", "mp": "minus or plus",
        "times": "times", "cdot": "dot", "cdots": "dot dot dot",
        "ldots": "dot dot dot", "vdots": "vertical dots", "ddots": "diagonal dots",
        "leq": "less than or equal to", "geq": "greater than or equal to",
        "le": "less than or equal to", "ge": "greater than or equal to",
        "neq": "not equal to", "ne": "not equal to",
        "approx": "approximately", "sim": "approximately",
        "simeq": "approximately equal to",
        "equiv": "equivalent to", "propto": "proportional to",
        "in": "in", "notin": "not in", "subset": "subset of", "supset": "superset of",
        "subseteq": "subset of or equal to", "supseteq": "superset of or equal to",
        "cup": "union", "cap": "intersection", "setminus": "minus",
        "emptyset": "empty set", "varnothing": "empty set",
        "forall": "for all", "exists": "there exists", "nexists": "there does not exist",
        "neg": "not", "lnot": "not", "land": "and", "lor": "or",
        "rightarrow": "to", "leftarrow": "from", "leftrightarrow": "to and from",
        "Rightarrow": "implies", "Leftarrow": "is implied by",
        "Leftrightarrow": "if and only if", "iff": "if and only if",
        "mapsto": "maps to", "to": "to", "gets": "from",
        "uparrow": "up", "downarrow": "down",
        "oplus": "direct sum", "otimes": "tensor product",
        "wedge": "wedge", "vee": "vee",
        "perp": "perpendicular to", "parallel": "parallel to",
        "angle": "angle", "triangle": "triangle",
        "therefore": "therefore", "because": "because",
        "dagger": "dagger", "ddagger": "double dagger",
        "ell": "l", "Re": "real part of", "Im": "imaginary part of",
    ]
    static let mathSymPattern: String =
        "\\\\(" + lengthDescending(mathSymOrder).joined(separator: "|") + ")(?![a-zA-Z])"

    // _SIZING_RE
    static let sizingPattern: String = "\\\\(?:" + [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
        "biggl", "biggr", "displaystyle", "textstyle", "scriptstyle",
        "scriptscriptstyle", "normalsize", "small", "footnotesize",
    ].joined(separator: "|") + ")(?![a-zA-Z])"

    // _FUNCS (reference order, joined without length sort).
    static let funcs: [String] = [
        "arcsin", "arccos", "arctan", "arccot",
        "sinh", "cosh", "tanh", "coth",
        "sin", "cos", "tan", "cot", "sec", "csc",
        "log", "ln", "exp", "det", "tr", "rank", "dim",
        "ker", "coker", "im", "span", "grad", "div", "curl",
    ]
    static let funcsPattern: String =
        "\\\\(" + funcs.joined(separator: "|") + ")(?![a-zA-Z])"

    static let mathbb: [String: String] = [
        "R": "the reals", "C": "the complex numbers", "Z": "the integers",
        "N": "the natural numbers", "Q": "the rationals",
    ]
    static let mathcal: [String: String] = [
        "O": "big-O", "L": "Lagrangian", "H": "Hamiltonian",
    ]

    // siunitx data.
    static let siPrefixTex: [String: String] = [
        "nano": "nano", "micro": "micro", "milli": "milli", "kilo": "kilo",
        "mega": "mega", "giga": "giga", "tera": "tera", "pico": "pico",
        "femto": "femto", "centi": "centi", "deci": "deci", "hecto": "hecto",
    ]
    static let siUnitTex: [String: String] = [
        "meter": "meter", "metre": "meter", "gram": "gram", "second": "second",
        "kelvin": "kelvin", "joule": "joule", "watt": "watt", "hertz": "hertz",
        "newton": "newton", "volt": "volt", "ohm": "ohm", "pascal": "pascal",
        "liter": "liter", "litre": "liter", "ampere": "ampere", "mole": "mole",
        "candela": "candela", "tesla": "tesla", "farad": "farad", "henry": "henry",
        "siemens": "siemens", "becquerel": "becquerel", "gray": "gray",
        "sievert": "sievert", "weber": "weber", "electronvolt": "electronvolt",
        "bar": "bar", "angstrom": "angstrom", "degree": "degree",
    ]

    /// _math_to_speech: convert a LaTeX math expression to word-form English.
    static func mathToSpeech(_ expr: String) -> String {
        var t = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip display delimiters.
        for p in [#"^\s*\$\$|\$\$\s*$"#, #"^\s*\\\[|\\\]\s*$"#,
                  #"^\s*\\\(|\\\)\s*$"#, #"^\s*\$|\$\s*$"#] {
            t = t.sub(p, "")
        }
        // Text inside math.
        t = t.sub(#"\\text(?:rm|bf|it|sf|tt)?\{([^{}]*)\}"#, " $1 ")
        t = t.sub(#"\\operatorname\{([^{}]+)\}"#, "$1")
        t = t.sub(#"\\mathrm\{([^{}]+)\}"#, "$1")
        // Fractions (nested: repeat).
        for _ in 0..<6 {
            t = t.sub(#"\\[cdt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, "$1 over $2")
        }
        // Binomial.
        for _ in 0..<3 {
            t = t.sub(#"\\binom\{([^{}]*)\}\{([^{}]*)\}"#, "$1 choose $2")
        }
        // Roots.
        t = t.sub(#"\\sqrt\[([^\]]+)\]\{([^{}]*)\}"#, "$1-th root of $2")
        t = t.sub(#"\\sqrt\{([^{}]*)\}"#, "square root of $1")
        t = t.sub(#"\\sqrt\s+(\w)"#, "square root of $1")
        // Integrals.
        t = t.sub(#"\\(?:oint|iint|iiint)\b"#, "\\\\int")
        t = t.sub(#"\\int\s*_\{([^{}]+)\}\s*\^\{([^{}]+)\}"#, "integral from $1 to $2 of")
        t = t.sub(#"\\int\s*_\{([^{}]+)\}\s*\^([^{\s])"#, "integral from $1 to $2 of")
        t = t.sub(#"\\int\s*_([^{\s])\s*\^\{([^{}]+)\}"#, "integral from $1 to $2 of")
        t = t.sub(#"\\int\s*_([^{\s])\s*\^([^{\s])"#, "integral from $1 to $2 of")
        t = t.sub(#"\\int\b"#, "integral of")
        // Sums / products.
        t = t.sub(#"\\sum\s*_\{([^{}]+)\}\s*\^\{([^{}]+)\}"#, "sum from $1 to $2 of")
        t = t.sub(#"\\sum\b"#, "sum of")
        t = t.sub(#"\\prod\s*_\{([^{}]+)\}\s*\^\{([^{}]+)\}"#, "product from $1 to $2 of")
        t = t.sub(#"\\prod\b"#, "product of")
        t = t.sub(#"\\bigcup\b"#, "union of")
        t = t.sub(#"\\bigcap\b"#, "intersection of")
        // Limits.
        t = t.sub(#"\\arg\s*\\max\b"#, "argmax")
        t = t.sub(#"\\arg\s*\\min\b"#, "argmin")
        t = t.sub(#"\\lim\s*_\{([^{}]+)\}"#, "limit as $1 of")
        t = t.sub(#"\\lim\b"#, "limit")
        t = t.sub(#"\\sup\b"#, "supremum")
        t = t.sub(#"\\inf\b"#, "infimum")
        t = t.sub(#"\\max\b"#, "max")
        t = t.sub(#"\\min\b"#, "min")
        // Derivatives (dot notation).
        t = t.sub(#"\\dddot\{([^{}]*)\}"#, "$1 triple dot")
        t = t.sub(#"\\ddot\{([^{}]*)\}"#, "$1 double dot")
        t = t.sub(#"\\dot\{([^{}]*)\}"#, "$1 dot")
        // Decorated symbols.
        t = t.sub(#"\\hat\{([^{}]*)\}"#, "$1 hat")
        t = t.sub(#"\\bar\{([^{}]*)\}"#, "$1 bar")
        t = t.sub(#"\\tilde\{([^{}]*)\}"#, "$1 tilde")
        t = t.sub(#"\\vec\{([^{}]*)\}"#, "vector $1")
        t = t.sub(#"\\overline\{([^{}]*)\}"#, "$1 bar")
        t = t.sub(#"\\overrightarrow\{([^{}]*)\}"#, "vector $1")
        t = t.sub(#"\\widehat\{([^{}]*)\}"#, "$1 hat")
        t = t.sub(#"\\widetilde\{([^{}]*)\}"#, "$1 tilde")
        t = t.sub(#"\\underbrace\{([^{}]*)\}_\{([^{}]*)\}"#, "$1, that is $2,")
        t = t.sub(#"\\overbrace\{([^{}]*)\}"#, "$1")
        // Matrix environments.
        t = t.sub(#"\\begin\{[pPbBvV]?matrix\*?\}(.*?)\\end\{[pPbBvV]?matrix\*?\}"#,
                  options: [.dotMatchesLineSeparators]) { m in
            let rows = (m[1] ?? "").splitRegex(#"\\\\"#)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let rowTexts = rows.map { row in
                row.components(separatedBy: "&")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            }
            if rowTexts.count == 1 {
                return "the vector " + rowTexts[0]
            }
            return "the matrix with rows: " + rowTexts.joined(separator: "; ")
        }
        // Cases.
        t = t.sub(#"\\begin\{cases\}(.*?)\\end\{cases\}"#,
                  options: [.dotMatchesLineSeparators]) { m in
            "cases: " + (m[1] ?? "").sub(#"\\\\"#, "; ").replacingOccurrences(of: "&", with: ",")
        }
        // Sizing commands (with optional delimiter).
        t = t.sub(#"\\(?:left|right)\s*(?:\\[a-zA-Z]+|[()\[\]|./])"#, " ")
        t = t.sub(sizingPattern, " ")
        // Equation tags.
        t = t.sub(#"\\tag\*?\{([^{}]*)\}"#, "(equation $1)")
        t = t.sub(#"\\(?:notag|nonumber)\b"#, "")
        // Separate adjacent single-letter variables before exponents: mc^2 -> m c^2.
        t = t.sub(#"(?<![a-zA-Z\\])([a-zA-Z])([a-zA-Z])(?=[_^])"#, "$1 $2")
        // Superscripts.
        t = t.sub(#"\^\{2\}"#, " squared")
        t = t.sub(#"\^\{3\}"#, " cubed")
        t = t.sub(#"\^\{-1\}"#, " inverse")
        t = t.sub(#"\^\{T\}"#, " transpose")
        t = t.sub(#"\^\{\s*\\dagger\s*\}"#, " dagger")
        t = t.sub(#"\^\{([^{}]+)\}"#, " to the $1")
        t = t.sub(#"\^2(?![0-9])"#, " squared")
        t = t.sub(#"\^3(?![0-9])"#, " cubed")
        t = t.sub(#"\^([A-Za-z0-9])"#, " to the $1")
        // Subscripts.
        t = t.sub(#"_\{([^{}]+)\}"#, " sub $1")
        t = t.sub(#"_([A-Za-z0-9])"#, " sub $1")
        // Greek letters.
        t = t.sub(greekTexPattern) { m in " " + (greekTex[m[1] ?? ""] ?? "") + " " }
        // Math symbols.
        t = t.sub(mathSymPattern) { m in " " + (mathSym[m[1] ?? ""] ?? "") + " " }
        // mathbb / mathcal / mathfrak / mathscr.
        t = t.sub(#"\\mathbb\{([^{}]*)\}"#) { m in mathbb[m[1] ?? ""] ?? (m[1] ?? "") }
        t = t.sub(#"\\mathcal\{([^{}]*)\}"#) { m in mathcal[m[1] ?? ""] ?? (m[1] ?? "") }
        for cmd in ["mathfrak", "mathscr"] {
            t = t.sub("\\\\" + cmd + #"\{([^{}]*)\}"#, "$1")
        }
        // Standard functions.
        t = t.sub(funcsPattern) { m in m[1] ?? "" }
        // Spacing commands.
        t = t.sub(#"\\[,;:!]|\\quad\b|\\qquad\b"#, " ")
        t = t.sub(#"\\hspace\{[^{}]*\}|\\vspace\{[^{}]*\}"#, " ")
        // Remaining braces.
        t = t.sub(#"[{}]"#, "")
        // Operators.
        t = t.sub(#"([^<>!])=(?!=)"#, "$1 equals ")
        t = t.sub(#"(?<![<>])\+(?!\+)"#, " plus ")
        t = t.sub(#"(?<=\s)-(?=\s)"#, " minus ")
        t = t.sub(#">(?!=)"#, " greater than ")
        t = t.sub(#"<(?!=)"#, " less than ")
        // Function application: f(x) -> f of x.
        t = t.sub(#"\b([a-zA-Z])\(([^()]*)\)"#, "$1 of $2")
        // Residual backslash commands.
        t = t.sub(#"\\[a-zA-Z]+"#, " ")
        t = t.sub(#"\\[^a-zA-Z\s]"#, " ")
        // Collapse spaces.
        t = t.sub(#" {2,}"#, " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// _process_text: text content within LaTeX environments (L4 text macros + L5 math only).
    static func processText(_ input: String) -> String {
        var text = input
        // Inline math within text.
        text = text.sub(#"\$(.*?)\$"#) { m in " " + mathToSpeech(m[1] ?? "") + " " }
        text = text.sub(#"\\\((.*?)\\\)"#) { m in " " + mathToSpeech(m[1] ?? "") + " " }
        // Text formatting.
        text = text.sub(#"\\(?:textit|emph|textsl|textbf|textsc|texttt|textsf)\{([^{}]*)\}"#, "$1")
        text = text.sub(#"\\(?:cite|citep|citet)\*?(?:\[[^\]]*\])?\{[^}]*\}"#, "")
        text = text.sub(#"\\label\{[^}]+\}"#, "")
        text = text.replacingOccurrences(of: "~", with: " ")
        // Residual commands (intentionally aggressive: better silent loss than garbage speech).
        text = text.sub(#"\\[a-zA-Z]+(?:\{[^{}]*\})?"#, " ")
        text = text.sub(#"[{}]"#, "")
        text = text.sub(#" {2,}"#, " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// _siunitx_expand: expand a siunitx unit specification to spoken words.
    static func siunitxExpand(_ unitSpec: String, value: String? = nil) -> String {
        let singular = value.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .containsMatch(#"^1(?:\.0+)?$"#)
        } ?? false
        let segments = unitSpec.splitRegex(#"\\per\b"#)
        var parts: [String] = []
        for (i, seg) in segments.enumerated() {
            var words: [String] = []
            var pendingPrefix = ""
            for m in seg.allMatches(#"\\([a-zA-Z]+)"#) {
                let cmd = m[1] ?? ""
                if let p = siPrefixTex[cmd] {
                    pendingPrefix += p
                } else if let u = siUnitTex[cmd] {
                    var unit = pendingPrefix + u
                    pendingPrefix = ""
                    if i == 0 && !singular { unit += "s" }
                    words.append(unit)
                } else if cmd == "squared" {
                    if !words.isEmpty { words[words.count - 1] += " squared" }
                } else if cmd == "cubed" {
                    if !words.isEmpty { words[words.count - 1] += " cubed" }
                } else if cmd == "per" {
                    // handled by split
                } else {
                    words.append(pendingPrefix + cmd)
                    pendingPrefix = ""
                }
            }
            if !pendingPrefix.isEmpty { words.append(pendingPrefix) }
            parts.append(words.joined(separator: " "))
        }
        return parts.joined(separator: " per ")
    }
}
