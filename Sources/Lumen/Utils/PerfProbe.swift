import AppKit
import QuartzCore
import SwiftUI

/// TEMPORARY measurement rig — every line of output is tagged [LumenPerf].
/// Enabled with LUMEN_PERF=1; LUMEN_PERF_DRIVE=1 additionally runs a scripted
/// interaction tour against the live model. Removed after profiling.
enum Perf {
    static let on = ProcessInfo.processInfo.environment["LUMEN_PERF"] == "1"
    static let drive = ProcessInfo.processInfo.environment["LUMEN_PERF_DRIVE"] == "1"

    /// Time a synchronous computation; log when it exceeds `threshold` ms.
    @inline(__always)
    static func time<T>(_ label: @autoclosure () -> String, threshold: Double = 0.3, _ work: () -> T) -> T {
        guard on else { return work() }
        let t0 = CACurrentMediaTime()
        let result = work()
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms >= threshold { NSLog("[LumenPerf] %@ %.2fms", label(), ms) }
        return result
    }

    // MARK: - View body accounting

    private final class BodyStats: @unchecked Sendable {
        var counts: [String: Int] = [:]
        var totalMs: [String: Double] = [:]
    }
    private static let stats = BodyStats()

    /// Wrap a view body: counts evaluations, logs slow builds (>0.5ms), and
    /// dumps cumulative counts every 60 evals so re-evaluation storms show up.
    static func body<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> V {
        guard on else { return content() }
        let t0 = CACurrentMediaTime()
        let v = content()
        let ms = (CACurrentMediaTime() - t0) * 1000
        stats.counts[label, default: 0] += 1
        stats.totalMs[label, default: 0] += ms
        let n = stats.counts[label]!
        if ms > 0.5 { NSLog("[LumenPerf] body %@ #%d %.2fms", label, n, ms) }
        if n % 60 == 0 {
            NSLog("[LumenPerf] bodycount %@ evals=%d total=%.1fms", label, n, stats.totalMs[label]!)
        }
        return v
    }

    // MARK: - Main-thread hitch monitor

    @MainActor private static var hitchTimer: Timer?

    /// Log main-runloop stalls (>50ms between 120Hz ticks) — catches work that
    /// blocks rendering even when no probe covers it.
    @MainActor static func startHitchMonitor() {
        guard on, hitchTimer == nil else { return }
        var last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
            let now = CACurrentMediaTime()
            let gap = (now - last) * 1000
            if gap > 50 { NSLog("[LumenPerf] HITCH %.0fms", gap) }
            last = now
        }
        RunLoop.main.add(t, forMode: .common)
        hitchTimer = t
    }

    // MARK: - Scripted tour

    @MainActor private static var driving = false

    /// Drive the app through the SwiftUI-heavy paths with the real 61k library:
    /// sidebar scope hops, sort change, search, list view, month grid, viewer,
    /// big selections. Each step is logged so hitches correlate to actions.
    @MainActor static func autodrive(_ model: AppModel) {
        guard on, drive, !driving else { return }
        driving = true
        Task { @MainActor in
            func step(_ name: String, _ work: () -> Void) async {
                try? await Task.sleep(for: .milliseconds(1500))
                NSLog("[LumenPerf] STEP %@", name)
                let t0 = CACurrentMediaTime()
                work()
                let ms = (CACurrentMediaTime() - t0) * 1000
                NSLog("[LumenPerf] STEP %@ sync=%.1fms", name, ms)
            }

            // Wait for the library.
            while model.totalCount == 0 { try? await Task.sleep(for: .milliseconds(300)) }
            try? await Task.sleep(for: .seconds(2))
            NSLog("[LumenPerf] DRIVE start, photos=%d", model.totalCount)

            let folders = model.stats.folderCounts.sorted { $0.value > $1.value }.map(\.key)
            if folders.count >= 2 {
                await step("folder-big") { model.selectedSidebar = .folder(folders[0]) }
                await step("folder-mid") { model.selectedSidebar = .folder(folders[folders.count / 2]) }
                await step("all-photos") { model.selectedSidebar = .allPhotos }
            }
            await step("sort-name") { model.sortOrder = .nameAZ }
            try? await Task.sleep(for: .seconds(2))   // async sort lands
            await step("sort-date") { model.sortOrder = .dateNewest }
            try? await Task.sleep(for: .seconds(2))
            await step("search-set") { model.searchText = "2019" }
            try? await Task.sleep(for: .seconds(2))
            await step("search-clear") { model.searchText = "" }
            await step("select-500") { model.selectAll(Array(model.visiblePhotos.prefix(500))) }
            await step("select-one") {
                if let p = model.visiblePhotos.first { model.selectOnly(p) }
            }
            await step("list-view") { model.viewMode = .list }
            try? await Task.sleep(for: .seconds(3))
            await step("list-select-500") { model.selectAll(Array(model.visiblePhotos.prefix(500))) }
            await step("grid-view") { model.viewMode = .grid }
            await step("month-on") { model.groupByMonth = true }
            try? await Task.sleep(for: .seconds(3))
            await step("month-off") { model.groupByMonth = false }
            await step("viewer-open") {
                if let p = model.visiblePhotos.first { model.openViewer(p) }
            }
            for i in 1...5 {
                await step("viewer-step-\(i)") { model.viewerStep(1) }
            }
            await step("viewer-close") { model.closeViewer() }
            await step("thumb-size") { model.thumbnailSize = 160 }
            await step("thumb-size-back") { model.thumbnailSize = 320 }
            NSLog("[LumenPerf] DRIVE done")
        }
    }
}
