import Foundation
@testable import LumenKit

/// CrashReporter's user-facing pieces (issue URL, handled-marking). The signal
/// handler itself is exercised by crashing a live app — not unit-testable.
func crashReporterTests() {
    func tempReport(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-test-\(UUID().uuidString).crash")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    test("gitHubIssueURLEmbedsReportAndTitle") {
        let report = try tempReport("Lumen 0.3.7\nmacOS 26.4\nFatal signal 11\n\n0  libsystem…")
        defer { try? FileManager.default.removeItem(at: report) }

        let url = CrashReporter.gitHubIssueURL(for: report)
        checkNotNil(url)
        let s = url!.absoluteString
        check(s.hasPrefix("https://github.com/rescenedev/lumen/issues/new?"),
              "should target the new-issue page: \(s)")
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let title = comps.queryItems?.first(where: { $0.name == "title" })?.value ?? ""
        let body = comps.queryItems?.first(where: { $0.name == "body" })?.value ?? ""
        checkEqual(title, "Crash report: Lumen 0.3.7")
        check(body.contains("Fatal signal 11"), "body should embed the report text")
        check(body.contains("nothing was sent automatically"), "body should carry the privacy note")
    }

    test("gitHubIssueURLTruncatesHugeReports") {
        let report = try tempReport(String(repeating: "x", count: 50_000))
        defer { try? FileManager.default.removeItem(at: report) }

        let url = CrashReporter.gitHubIssueURL(for: report)
        checkNotNil(url)
        check(url!.absoluteString.count < 20_000,
              "URL must stay within browser/GitHub limits, got \(url!.absoluteString.count)")
    }

    test("markHandledRenamesSoItNeverRePrompts") {
        let report = try tempReport("Lumen 0.0.0\ncrash")
        CrashReporter.markHandled(report)
        defer { try? FileManager.default.removeItem(at: report.appendingPathExtension("handled")) }

        check(!FileManager.default.fileExists(atPath: report.path), "original .crash should be gone")
        check(FileManager.default.fileExists(atPath: report.appendingPathExtension("handled").path),
              ".crash.handled should exist")
    }
}
