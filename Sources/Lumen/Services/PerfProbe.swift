import AppKit

/// Nearest-rank percentile statistics over millisecond samples.
struct TimingStats: Codable {
    let count: Int
    let avg: Double
    let p50: Double
    let p95: Double
    let max: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        guard !sorted.isEmpty else { avg = 0; p50 = 0; p95 = 0; max = 0; return }
        avg = sorted.reduce(0, +) / Double(sorted.count)
        func rank(_ p: Double) -> Double {
            sorted[Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
        }
        p50 = rank(0.50)
        p95 = rank(0.95)
        max = sorted.last ?? 0
    }
}

/// Main-thread hitch analysis from a high-frequency timer's fire timestamps:
/// any gap beyond `hitchThreshold` means the main thread was blocked.
struct HitchAnalysis: Codable {
    let tickCount: Int
    let hitchCount: Int
    let maxGapMs: Double

    init(tickTimestamps: [Double], hitchThreshold: Double) {
        tickCount = tickTimestamps.count
        guard tickTimestamps.count >= 2 else { hitchCount = 0; maxGapMs = 0; return }
        var hitches = 0
        var maxGap = 0.0
        for i in 1..<tickTimestamps.count {
            let gap = tickTimestamps[i] - tickTimestamps[i - 1]
            if gap > hitchThreshold { hitches += 1 }
            if gap > maxGap { maxGap = gap }
        }
        hitchCount = hitches
        maxGapMs = maxGap * 1000
    }
}

/// The probe's output, written as JSON to $LUMEN_PERF_REPORT.
struct PerfReport: Codable {
    var appVersion: String
    var photoCount: Int
    var launchToLibraryMs: Double?
    var folderOpen: TimingStats?
    var libraryScopesMs: [String: Double] = [:]
    var searchMs: Double?
    var selectAllMs: Double?
    var hitch: HitchAnalysis?
    var footprintMB: Int?

    init(appVersion: String, photoCount: Int) {
        self.appVersion = appVersion
        self.photoCount = photoCount
    }
}

/// Env-gated, read-only launch benchmark. Launch the app with
/// `LUMEN_PERF_REPORT=/path/report.json`: after the library is ready the probe
/// sweeps every folder scope, measures search/select-all main-thread costs and
/// hitches during the sweep, writes the JSON report, and terminates the app.
/// Inert (nil) in normal runs.
@MainActor
final class PerfProbe {
    static let shared: PerfProbe? =
        ProcessInfo.processInfo.environment["LUMEN_PERF_REPORT"].map { PerfProbe(reportPath: $0) }

    private let reportPath: String
    private let startedAt = CFAbsoluteTimeGetCurrent()
    private var libraryReadyAt: CFAbsoluteTime?

    private init(reportPath: String) {
        self.reportPath = reportPath
    }

    /// Called from the app-launch pipeline the moment the grid's backing list
    /// is installed. Waits a short settle (thumbnail decodes, first layout),
    /// then runs the scenario exactly once.
    func markLibraryReady(_ model: AppModel) {
        guard libraryReadyAt == nil else { return }
        libraryReadyAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak model] in
            guard let model else { return }
            Task { @MainActor in self.run(model) }
        }
    }

    private func run(_ model: AppModel) {
        var report = PerfReport(appVersion: UpdateChecker.currentVersion,
                                photoCount: model.allPhotos.count)
        if let ready = libraryReadyAt {
            report.launchToLibraryMs = (ready - startedAt) * 1000
        }

        // Hitch monitor: a 240Hz timer on the main run loop; every stall in
        // the measured section below shows up as a fire-gap.
        var ticks: [Double] = []
        ticks.reserveCapacity(20_000)
        let monitor = Timer(timeInterval: 1.0 / 240.0, repeats: true) { _ in
            ticks.append(CFAbsoluteTimeGetCurrent())
        }
        RunLoop.main.add(monitor, forMode: .common)

        // Library scopes, then every folder — the sweep itself yields to the
        // run loop between folders so the hitch monitor can observe each one.
        for (name, item) in [("allPhotos", SidebarItem.allPhotos),
                             ("favorites", .favorites),
                             ("onThisDay", .onThisDay)] {
            report.libraryScopesMs[name] = model.probeCommit(item) * 1000
        }
        let folders = model.photoFolders
        var folderSamples: [Double] = []
        folderSamples.reserveCapacity(folders.count)

        func sweep(_ index: Int) {
            if index >= folders.count {
                finish()
                return
            }
            folderSamples.append(model.probeCommit(.folder(folders[index])) * 1000)
            // Paced, not main.async-chained: a continuous dispatch flood
            // starves run-loop timers, so the hitch monitor would report
            // scheduling artifacts instead of real main-thread stalls.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { sweep(index + 1) }
        }

        func finish() {
            report.folderOpen = TimingStats(samples: folderSamples)

            _ = model.probeCommit(.allPhotos)
            var t0 = CFAbsoluteTimeGetCurrent()
            model.searchText = "2024"
            _ = model.visiblePhotos
            report.searchMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            model.searchText = ""
            _ = model.visiblePhotos

            t0 = CFAbsoluteTimeGetCurrent()
            model.selectAll(model.allPhotos)   // visiblePhotos may still be mid-async-sort
            report.selectAllMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            model.clearSelection()

            monitor.invalidate()
            report.hitch = HitchAnalysis(tickTimestamps: ticks, hitchThreshold: 0.033)
            report.footprintMB = Self.physFootprintMB()

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                try? data.write(to: URL(fileURLWithPath: self.reportPath))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApplication.shared.terminate(nil)
            }
        }

        sweep(0)
    }

    /// The process's physical memory footprint (what Activity Monitor shows).
    private static func physFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / (1024 * 1024))
    }
}
