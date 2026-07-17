import Foundation
@testable import LumenKit

/// Pure pieces of the env-gated launch benchmark (LUMEN_PERF_REPORT=path):
/// timing statistics, main-thread hitch analysis, and the JSON report shape.
/// The probe itself is integration-only (drives a live AppModel and quits);
/// these tests pin the math it reports.
func perfProbeTests() {

    // MARK: TimingStats

    test("TimingStats: avg/p50/p95/max over a known distribution") {
        let samples = (1...100).map { Double($0) }   // 1..100 ms
        let s = TimingStats(samples: samples)
        checkEqual(s.count, 100)
        check(abs(s.avg - 50.5) < 0.001)
        checkEqual(s.max, 100)
        checkEqual(s.p50, 50, "p50 of 1..100 (nearest-rank) is the 50th sample")
        checkEqual(s.p95, 95, "p95 of 1..100 (nearest-rank) is the 95th sample")
    }

    test("TimingStats: single sample and empty input") {
        let one = TimingStats(samples: [7])
        checkEqual(one.avg, 7); checkEqual(one.p95, 7); checkEqual(one.max, 7)
        let none = TimingStats(samples: [])
        checkEqual(none.count, 0); checkEqual(none.avg, 0); checkEqual(none.max, 0)
    }

    test("TimingStats: unsorted input is handled") {
        let s = TimingStats(samples: [30, 10, 20])
        checkEqual(s.p50, 20)
        checkEqual(s.max, 30)
    }

    // MARK: Hitch analysis

    test("HitchAnalysis: steady 120Hz ticks produce no hitches") {
        let ticks = (0..<240).map { Double($0) / 120.0 }   // perfect 2s of 120Hz
        let h = HitchAnalysis(tickTimestamps: ticks, hitchThreshold: 0.033)
        checkEqual(h.hitchCount, 0)
        check(h.maxGapMs < 9)
    }

    test("HitchAnalysis: a stall shows up as max gap and one hitch") {
        var ticks = (0..<120).map { Double($0) / 120.0 }
        let last = ticks.last!
        ticks += (1...60).map { last + 0.250 + Double($0) / 120.0 }   // 250ms stall, then steady
        let h = HitchAnalysis(tickTimestamps: ticks, hitchThreshold: 0.033)
        checkEqual(h.hitchCount, 1)
        check(abs(h.maxGapMs - 258.3) < 2, "max gap should be ~250ms + one frame (got \(h.maxGapMs))")
    }

    test("HitchAnalysis: fewer than 2 ticks is a clean zero") {
        let h = HitchAnalysis(tickTimestamps: [1.0], hitchThreshold: 0.033)
        checkEqual(h.hitchCount, 0); checkEqual(h.maxGapMs, 0)
    }

    // MARK: Report shape

    test("PerfReport: encodes to JSON and round-trips") {
        var report = PerfReport(appVersion: "0.5.3", photoCount: 66_849)
        report.launchToLibraryMs = 512.3
        report.folderOpen = TimingStats(samples: [1, 2, 3])
        report.searchMs = 12.5
        report.selectAllMs = 180
        report.hitch = HitchAnalysis(tickTimestamps: [0, 0.008, 0.016], hitchThreshold: 0.033)
        report.footprintMB = 397

        let data = try JSONEncoder().encode(report)
        let back = try JSONDecoder().decode(PerfReport.self, from: data)
        checkEqual(back.appVersion, "0.5.3")
        checkEqual(back.photoCount, 66_849)
        checkEqual(back.folderOpen?.count, 3)
        checkEqual(back.footprintMB, 397)
    }
}
