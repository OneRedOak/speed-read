import Foundation

/// Daily spend tracking and budget enforcement (C-1, C-2, C-3).
///
/// Spend is recorded from the ElevenLabs `character-cost` response header
/// (exact billed credits, live-verified) — not estimated from input length.
/// `UserDefaults` supports concurrent reads/writes, while the only compound
/// mutation (`record`) is serialized by `recordLock`.
public struct CostLedger: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let day = "costDay"
        static let spent = "costSpentToday"
        static let budget = "dailyCharacterBudget"
        static let overrideDay = "budgetOverrideDay"
        static let largeReadThreshold = "largeReadThreshold"
    }

    /// Thread-safe local calendar day stamp that tracks timezone changes
    /// dynamically (avoiding non-thread-safe shared `DateFormatter`).
    private var today: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.autoupdatingCurrent
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Daily character budget (C-2). Default 30,000 ≈ a few long articles.
    public var dailyBudget: Int {
        get {
            defaults.object(forKey: Key.budget) == nil
                ? 30_000 : defaults.integer(forKey: Key.budget)
        }
        nonmutating set { defaults.set(max(0, newValue), forKey: Key.budget) }
    }

    /// Selections above this prompt for confirmation (C-3). Default 8,000.
    public var largeReadThreshold: Int {
        get {
            defaults.object(forKey: Key.largeReadThreshold) == nil
                ? 8_000 : defaults.integer(forKey: Key.largeReadThreshold)
        }
        nonmutating set { defaults.set(max(0, newValue), forKey: Key.largeReadThreshold) }
    }

    public var spentToday: Int {
        guard defaults.string(forKey: Key.day) == today else { return 0 }
        return max(defaults.integer(forKey: Key.spent), 0)
    }

    /// Serializes the read-modify-write: up to 3 pipeline chunks can bill
    /// concurrently, and racing increments would silently undercount spend.
    private static let recordLock = NSLock()

    public func record(billedCharacters: Int) {
        let delta = max(billedCharacters, 0)
        guard delta > 0 else { return }
        Self.recordLock.lock()
        defer { Self.recordLock.unlock() }
        let day = today
        let base = defaults.string(forKey: Key.day) == day
            ? max(defaults.integer(forKey: Key.spent), 0) : 0
        defaults.set(day, forKey: Key.day)
        defaults.set(base + delta, forKey: Key.spent)
    }

    /// One-click override: budget ignored for the rest of today (C-2).
    public var overriddenToday: Bool {
        get { defaults.string(forKey: Key.overrideDay) == today }
        nonmutating set {
            defaults.set(newValue ? today : nil, forKey: Key.overrideDay)
        }
    }

    public enum BudgetVerdict: Equatable {
        case ok
        case warning(spent: Int, budget: Int)   // ≥ 80%
        case exceeded(spent: Int, budget: Int)  // ≥ 100%, hard stop
    }

    public func verdict() -> BudgetVerdict {
        if overriddenToday { return .ok }
        let spent = spentToday
        let budget = dailyBudget
        if spent >= budget { return .exceeded(spent: spent, budget: budget) }
        if Double(spent) >= Double(budget) * 0.8 { return .warning(spent: spent, budget: budget) }
        return .ok
    }
}
