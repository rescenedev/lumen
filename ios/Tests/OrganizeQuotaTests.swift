import XCTest

final class OrganizeQuotaTests: XCTestCase {
    private let jun11 = DateComponents(calendar: .current, year: 2026, month: 6, day: 11, hour: 10).date!
    private let jun12 = DateComponents(calendar: .current, year: 2026, month: 6, day: 12, hour: 1).date!

    func testFreshQuotaHasFullAllowance() {
        let q = OrganizeQuota(day: "", used: 99).rolled(to: jun11)
        XCTAssertEqual(q.day, "2026-06-11")
        XCTAssertEqual(q.remaining, OrganizeQuota.freeDailyLimit)
    }

    func testConsumeCountsDown() {
        var q = OrganizeQuota(day: "2026-06-11", used: 0)
        q = q.consumed().consumed().consumed()
        XCTAssertEqual(q.used, 3)
        XCTAssertEqual(q.remaining, OrganizeQuota.freeDailyLimit - 3)
    }

    func testRemainingNeverNegative() {
        let q = OrganizeQuota(day: "2026-06-11", used: OrganizeQuota.freeDailyLimit + 5)
        XCTAssertEqual(q.remaining, 0)
    }

    func testSameDayRollKeepsCount() {
        let q = OrganizeQuota(day: "2026-06-11", used: 7).rolled(to: jun11)
        XCTAssertEqual(q.used, 7)
    }

    func testNewDayResetsCount() {
        let q = OrganizeQuota(day: "2026-06-11", used: OrganizeQuota.freeDailyLimit).rolled(to: jun12)
        XCTAssertEqual(q.day, "2026-06-12")
        XCTAssertEqual(q.used, 0)
        XCTAssertEqual(q.remaining, OrganizeQuota.freeDailyLimit)
    }

    func testRefundGivesOneBackAndClampsAtZero() {
        let q = OrganizeQuota(day: "2026-06-11", used: 1)
        XCTAssertEqual(q.refunded().used, 0)
        XCTAssertEqual(q.refunded().refunded().used, 0)   // never below zero
    }
}
