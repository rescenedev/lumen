import Foundation
import Darwin

/// Privacy-preserving crash logging. Everything stays LOCAL: a crash writes a
/// plain-text report under Application Support/Lumen/CrashReports/, and the
/// next launch offers to open a prefilled GitHub issue — sending is always a
/// user action, never automatic, so the "nothing leaves your Mac" claim holds.
/// Reports contain only the app version, OS version, crash reason, and stack
/// symbols — never file paths, photo names, or library contents.
enum CrashReporter {
    private static let fatalSignals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
    private static let maxKeptReports = 5

    /// Pre-computed at install time: a signal handler may only call
    /// async-signal-safe functions (open/write/close/backtrace) — if the crash
    /// originated inside malloc, ANY allocation in the handler deadlocks on
    /// the allocator lock and the app hangs instead of crashing. So the path,
    /// header, per-signal messages, AND the backtrace frame buffer are all
    /// raw C allocations made up front; the handler only loads and writes.
    nonisolated(unsafe) private static var reportPathC: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var headerC: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static let signalMessages: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 32)
        p.initialize(repeating: nil, count: 32)
        return p
    }()
    nonisolated(unsafe) private static let framesBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
        let p = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
        p.initialize(repeating: nil, count: 128)
        return p
    }()

    static var reportsDirectory: URL {
        AppDirectories.applicationSupport()
            .appendingPathComponent("Lumen/CrashReports", isDirectory: true)
    }

    // MARK: - Install

    static func install() {
        let dir = reportsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let path = dir.appendingPathComponent("crash-\(stamp).crash").path
        let header = """
        Lumen \(UpdateChecker.currentVersion)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Crashed \(stamp)

        """
        reportPathC = strdup(path)
        headerC = strdup(header)
        for sig in fatalSignals where sig >= 0 && sig < 32 {
            signalMessages[Int(sig)] = strdup("Fatal signal \(sig)\n\n")
        }

        NSSetUncaughtExceptionHandler { exception in
            let body = """
            Uncaught exception: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")

            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            CrashReporter.writeReport(body)
        }
        for sig in fatalSignals {
            signal(sig, { sig in
                CrashReporter.handleSignal(sig)
            })
        }
        pruneOldReports()
    }

    /// Async-signal-safe path: ONLY open/write/close/backtrace on pre-allocated
    /// memory. No Swift strings, no Arrays, no allocation of any kind.
    private static func handleSignal(_ sig: Int32) {
        if let pathC = reportPathC {
            let fd = open(pathC, O_CREAT | O_WRONLY | O_APPEND, 0o644)
            if fd >= 0 {
                if let headerC {
                    _ = write(fd, headerC, strlen(headerC))
                }
                if sig >= 0, sig < 32, let message = signalMessages[Int(sig)] {
                    _ = write(fd, message, strlen(message))
                }
                let count = backtrace(framesBuffer, 128)
                backtrace_symbols_fd(framesBuffer, count, fd)
                close(fd)
            }
        }
        // Restore default disposition and re-raise so the OS report still happens.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// Uncaught-exception path — NOT signal context, so Foundation is fine here.
    private static func writeReport(_ body: String) {
        guard let pathC = reportPathC, let headerC else { return }
        let path = String(cString: pathC)
        let header = String(cString: headerC)
        try? (header + body).write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Next-launch handling

    /// Unhandled reports from previous sessions, newest first.
    static func pendingReports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "crash" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // ISO stamps sort lexically
    }

    /// Mark a report as seen so it never re-prompts (file stays on disk for
    /// manual inspection until pruned).
    static func markHandled(_ report: URL) {
        let handled = report.appendingPathExtension("handled")
        try? FileManager.default.moveItem(at: report, to: handled)
    }

    /// Prefilled new-issue URL. Body is truncated to stay within GitHub's URL
    /// limits; the full report stays on disk.
    static func gitHubIssueURL(for report: URL) -> URL? {
        guard let text = try? String(contentsOf: report, encoding: .utf8) else { return nil }
        let firstLine = String((text.split(separator: "\n").first ?? "Lumen").prefix(80))
        let body = """
        <!-- Generated locally by Lumen. Review before submitting — nothing was sent automatically. -->
        ```
        \(String(text.prefix(4_000)))
        ```
        """
        var comps = URLComponents(string: "https://github.com/rescenedev/lumen/issues/new")!
        comps.queryItems = [
            URLQueryItem(name: "title", value: "Crash report: \(firstLine)"),
            URLQueryItem(name: "body", value: body),
        ]
        return comps.url
    }

    private static func pruneOldReports() {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("crash-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in files.dropFirst(maxKeptReports) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
