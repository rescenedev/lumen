import StoreKit
import SwiftUI

/// Lumen Pro (one-time, non-consumable): unlimited organizing. The free tier
/// gets `OrganizeQuota.freeDailyLimit` keep/trash decisions per day — browsing
/// and favorites are always free.
@MainActor @Observable final class StoreManager {
    static let proID = "com.prototype.lumen.ios.pro"

    /// Last verified entitlement, cached so launch doesn't wait on StoreKit.
    private(set) var isPro = UserDefaults.standard.bool(forKey: "lumen.pro")
    private(set) var product: Product?
    private(set) var purchasing = false
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init() {
        // Keep entitlement fresh across devices/refunds (StoreKit pushes updates).
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let t) = update {
                    await t.finish()
                    await self?.refreshEntitlement()
                }
            }
        }
        Task {
            await refreshEntitlement()
            product = try? await Product.products(for: [Self.proID]).first
        }
    }

    func refreshEntitlement() async {
        var pro = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let t) = entitlement, t.productID == Self.proID, t.revocationDate == nil {
                pro = true
            }
        }
        isPro = pro
        UserDefaults.standard.set(pro, forKey: "lumen.pro")
    }

    @discardableResult
    func purchase() async -> Bool {
        guard let product, !purchasing else { return false }
        purchasing = true
        defer { purchasing = false }
        guard let result = try? await product.purchase() else { return false }
        if case .success(.verified(let t)) = result {
            await t.finish()
            await refreshEntitlement()
            return true
        }
        return false
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    // MARK: - Free-tier daily quota

    private func loadQuota(now: Date) -> OrganizeQuota {
        let d = UserDefaults.standard
        return OrganizeQuota(day: d.string(forKey: "lumen.quota.day") ?? "",
                             used: d.integer(forKey: "lumen.quota.used"))
            .rolled(to: now)
    }

    private func saveQuota(_ q: OrganizeQuota) {
        let d = UserDefaults.standard
        d.set(q.day, forKey: "lumen.quota.day")
        d.set(q.used, forKey: "lumen.quota.used")
    }

    func remainingToday(now: Date = .now) -> Int {
        isPro ? .max : loadQuota(now: now).remaining
    }

    func canOrganize(now: Date = .now) -> Bool {
        isPro || loadQuota(now: now).remaining > 0
    }

    func consumeOrganize(now: Date = .now) {
        guard !isPro else { return }
        saveQuota(loadQuota(now: now).consumed())
    }

    /// Undo hands the decision back.
    func refundOrganize(now: Date = .now) {
        guard !isPro else { return }
        saveQuota(loadQuota(now: now).refunded())
    }
}
