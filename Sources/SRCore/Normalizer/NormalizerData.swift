import Foundation

/// Shared data tables ported from reference/normalize.py (top section).
enum NormalizerData {
    /// _SD: superscript digit → ASCII digit.
    static let superscriptDigits: [Character: Character] = [
        "\u{00b9}": "1", "\u{00b2}": "2", "\u{00b3}": "3", "\u{2074}": "4",
        "\u{2075}": "5", "\u{2076}": "6", "\u{2077}": "7", "\u{2078}": "8",
        "\u{2079}": "9", "\u{2070}": "0",
    ]

    /// _SUP_RE
    static let supRe = "[\u{00b9}\u{00b2}\u{00b3}\u{2074}-\u{2079}\u{2070}]+"

    /// _COMPOUND_PREFIXES
    static let compoundPrefixes: Set<String> = [
        "self", "non", "quasi", "semi", "well", "ill", "all", "half", "cross", "ex",
    ]

    /// _CITATION_FOLLOWERS (function-word gate for PDF superscript citations).
    static let citationFollowers: [String] = [
        "that", "which", "and", "or", "but", "if", "as", "so", "yet",
        "the", "this", "these", "those", "it", "they", "we", "he", "she", "its",
        "has", "have", "had", "was", "were", "is", "are", "been", "can", "could",
        "would", "should", "may", "might", "shall", "will", "did", "does", "do",
        "also", "not", "often", "still", "even", "only", "just",
        "in", "on", "to", "for", "at", "by", "with", "from", "of",
        "showed", "found", "reported", "observed", "noted", "demonstrated",
        "suggested", "indicated", "revealed", "confirmed", "concluded",
    ]

    /// _NUM_CONTEXT_WORDS
    static let numContextWords: Set<String> = [
        "chapter", "section", "step", "phase", "stage", "type", "table", "figure",
        "page", "group", "item", "class", "level", "grade", "round", "trial",
        "volume", "number", "part", "act", "year", "day", "week", "month",
        "case", "rule", "task", "test", "dose", "factor", "version", "model",
        "least", "most", "only", "approximately", "about", "nearly", "almost",
        "over", "under", "around", "exactly", "roughly", "fewer", "more",
        "and", "or", "to", "from", "through", "between", "versus", "times", "equals",
        "another", "other", "further", "additional", "remaining",
        "next", "last", "first", "every", "each",
    ]

    /// _CITE_PAT (built from _CF_ALT).
    static let citePattern: String = {
        let alt = lengthDescending(citationFollowers).joined(separator: "|")
        return "(\\w+) (\\d{1,2}) (?=(" + alt + ")\\b)"
    }()

    /// _FRAC: unicode vulgar fractions → words.
    static let fractions: [(String, String)] = [
        ("\u{00bd}", "one half"), ("\u{2153}", "one third"), ("\u{00bc}", "one quarter"),
        ("\u{00be}", "three quarters"), ("\u{2154}", "two thirds"), ("\u{2155}", "one fifth"),
        ("\u{2156}", "two fifths"), ("\u{2157}", "three fifths"), ("\u{2158}", "four fifths"),
        ("\u{2159}", "one sixth"), ("\u{215a}", "five sixths"), ("\u{215b}", "one eighth"),
        ("\u{215c}", "three eighths"), ("\u{215d}", "five eighths"), ("\u{215e}", "seven eighths"),
    ]

    /// _ELEM: element symbol → name.
    static let elements: [String: String] = [
        "H": "hydrogen", "He": "helium", "Li": "lithium", "Be": "beryllium", "B": "boron",
        "C": "carbon", "N": "nitrogen", "O": "oxygen", "F": "fluorine", "Ne": "neon",
        "Na": "sodium", "Mg": "magnesium", "Al": "aluminum", "Si": "silicon",
        "P": "phosphorus", "S": "sulfur", "Cl": "chlorine", "Ar": "argon",
        "K": "potassium", "Ca": "calcium", "Fe": "iron", "Co": "cobalt", "Ni": "nickel",
        "Cu": "copper", "Zn": "zinc", "Se": "selenium", "Br": "bromine", "Kr": "krypton",
        "Sr": "strontium", "Mo": "molybdenum", "Tc": "technetium", "Ag": "silver",
        "Cd": "cadmium", "I": "iodine", "Xe": "xenon", "Cs": "cesium", "Ba": "barium",
        "La": "lanthanum", "Ce": "cerium", "Nd": "neodymium", "Sm": "samarium",
        "Eu": "europium", "Gd": "gadolinium", "Tb": "terbium", "Dy": "dysprosium",
        "Er": "erbium", "Yb": "ytterbium", "Lu": "lutetium", "Hf": "hafnium",
        "Ta": "tantalum", "W": "tungsten", "Re": "rhenium", "Os": "osmium",
        "Ir": "iridium", "Pt": "platinum", "Au": "gold", "Hg": "mercury",
        "Pb": "lead", "Bi": "bismuth", "Po": "polonium", "Rn": "radon",
        "Ra": "radium", "Th": "thorium", "U": "uranium", "Np": "neptunium",
        "Pu": "plutonium", "Am": "americium",
    ]

    /// _CHEM: formula → spoken name (insertion order preserved for parity).
    static let chemOrder: [String] = [
        "H2O", "CO2", "NaCl", "CH4", "NH3", "H2SO4", "HCl", "NaOH", "CaCO3",
        "Fe2O3", "C2H5OH", "C6H12O6", "CH3OH", "KOH", "HNO3", "Na2CO3", "MgO",
        "SiO2", "SO2", "NO2", "O3", "N2O", "C2H2", "C2H4", "C3H8", "ATP", "DNA", "RNA",
    ]
    static let chem: [String: String] = [
        "H2O": "water", "CO2": "carbon dioxide", "NaCl": "sodium chloride",
        "CH4": "methane", "NH3": "ammonia", "H2SO4": "sulfuric acid",
        "HCl": "hydrochloric acid", "NaOH": "sodium hydroxide",
        "CaCO3": "calcium carbonate", "Fe2O3": "iron oxide",
        "C2H5OH": "ethanol", "C6H12O6": "glucose", "CH3OH": "methanol",
        "KOH": "potassium hydroxide", "HNO3": "nitric acid",
        "Na2CO3": "sodium carbonate", "MgO": "magnesium oxide",
        "SiO2": "silicon dioxide", "SO2": "sulfur dioxide",
        "NO2": "nitrogen dioxide", "O3": "ozone", "N2O": "nitrous oxide",
        "C2H2": "acetylene", "C2H4": "ethylene", "C3H8": "propane",
        "ATP": "ATP", "DNA": "DNA", "RNA": "RNA",
    ]
    static let chemPattern: String =
        "\\b(" + lengthDescending(chemOrder).joined(separator: "|") + ")\\b"
}
