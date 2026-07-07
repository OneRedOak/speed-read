import Foundation

/// Daily spend tracking and budget enforcement (C-1, C-2, C-3).
///
/// Spend is recorded from the ElevenLabs `character-cost` response header
/// (exact billed credits, live-verified) — not estimated from input length.
public struct CostLedger {
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

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private var today: String { Self.dayFormat.string(from: Date()) }

    /// Daily character budget (C-2). Default 30,000 ≈ a few long articles.
    public var dailyBudget: Int {
        get {
            defaults.object(forKey: Key.budget) == nil
                ? 30_000 : defaults.integer(forKey: Key.budget)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.budget) }
    }

    /// Selections above this prompt for confirmation (C-3). Default 8,000.
    public var largeReadThreshold: Int {
        get {
            defaults.object(forKey: Key.largeReadThreshold) == nil
                ? 8_000 : defaults.integer(forKey: Key.largeReadThreshold)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.largeReadThreshold) }
    }

    public var spentToday: Int {
        guard defaults.string(forKey: Key.day) == today else { return 0 }
        return defaults.integer(forKey: Key.spent)
    }

    public func record(billedCharacters: Int) {
        let base = spentToday
        defaults.set(today, forKey: Key.day)
        defaults.set(base + billedCharacters, forKey: Key.spent)
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
        if spent * 5 >= budget * 4 { return .warning(spent: spent, budget: budget) }
        return .ok
    }
}
