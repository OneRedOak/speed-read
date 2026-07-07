import Foundation

/// Per-app routing rules (P-8), keyed on the frontmost app's bundle ID.
///
/// Stored as JSON at `~/Library/Application Support/sr/rules.json`:
/// `{ "com.1password.*": "block", "com.apple.mail": "force-local" }`.
/// A trailing `*` in a key is a prefix wildcard. Exact matches win over
/// wildcard matches; the longest wildcard prefix wins among wildcards.
public struct RoutingPolicy: Sendable {
    public enum Action: String, Sendable, Codable {
        case `default`
        case forceLocal = "force-local"
        case block
    }

    /// Password managers are blocked out of the box.
    public static let shippedDefaults: [String: Action] = [
        "com.1password.*": .block,
        "com.agilebits.onepassword*": .block,
        "com.apple.keychainaccess": .block,
        "com.apple.Passwords": .block,
        "com.bitwarden.*": .block,
        "com.lastpass.*": .block,
    ]

    public private(set) var rules: [String: Action]

    public static var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sr/rules.json")
    }

    public static func load() -> RoutingPolicy {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Action].self, from: data)
        else {
            let policy = RoutingPolicy(rules: shippedDefaults)
            policy.save()
            return policy
        }
        // Shipped defaults apply unless the user explicitly overrode them.
        var merged = shippedDefaults
        merged.merge(decoded) { _, user in user }
        return RoutingPolicy(rules: merged)
    }

    public init(rules: [String: Action]) {
        self.rules = rules
    }

    public func save() {
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? encoder.encode(rules))?.write(to: Self.fileURL, options: .atomic)
    }

    public mutating func set(_ action: Action, for bundleID: String) {
        rules[bundleID] = action
        save()
    }

    public func action(for bundleID: String?) -> Action {
        guard let bundleID, !bundleID.isEmpty else { return .default }
        if let exact = rules[bundleID] { return exact }
        let wildcard = rules
            .filter { $0.key.hasSuffix("*") && bundleID.hasPrefix($0.key.dropLast()) }
            .max { $0.key.count < $1.key.count }
        return wildcard?.value ?? .default
    }
}
