import Foundation

/// Free-tier daily organize allowance. Pure value logic (no StoreKit, no
/// UserDefaults) so it's unit-testable — StoreManager persists it.
struct OrganizeQuota: Equatable {
    static let freeDailyLimit = 30

    let day: String   // "2026-06-11"
    let used: Int

    static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The quota as of `date` — a new day resets the counter.
    func rolled(to date: Date) -> OrganizeQuota {
        let key = Self.dayKey(for: date)
        return key == day ? self : OrganizeQuota(day: key, used: 0)
    }

    var remaining: Int { max(0, Self.freeDailyLimit - used) }

    func consumed() -> OrganizeQuota { OrganizeQuota(day: day, used: used + 1) }

    /// Undo gives the swipe back — never below zero.
    func refunded() -> OrganizeQuota { OrganizeQuota(day: day, used: max(0, used - 1)) }
}
