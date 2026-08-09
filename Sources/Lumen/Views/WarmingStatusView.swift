import SwiftUI

/// Tiny status-bar view that shows background thumbnail-warming progress.
/// It observes `WarmingMonitor` directly, so the frequent progress ticks only
/// re-render this label — never the grid or sidebar.
struct WarmingStatusView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var warming: WarmingMonitor

    var body: some View {
        if warming.remaining > 0 {
            StatusRowButton {
                StatusRow(label: "Thumbnails",
                          detail: BackgroundWorkText.counts(done: warming.done, total: warming.total),
                          context: BackgroundWorkText.pace(rate: warming.rate, eta: warming.eta,
                                                           place: warming.folder),
                          failures: model.failures(.thumbnail).count) {
                    ThinProgressBar(fraction: warming.fraction)
                }
            } detail: {
                ThumbnailJobPopover(warming: warming)
            }
            .help("Building the thumbnail cache in the background so browsing is instant. "
                  + "Click for details and any photos that failed.")
        }
    }
}

/// Pure status-line wording for the long background jobs, kept out of the views
/// so the phrasing is unit-tested and consistent between them.
enum BackgroundWorkText {
    /// Always a fraction. A bare countdown ("Caching 29,412") is a number with
    /// nothing to measure it against. No percentage: the bar already says what
    /// share is done, and printing it twice is clutter, not clarity.
    /// `done` is clamped — a late tick from a superseded pass must never print
    /// a nonsense "1,262,045 of 84,254".
    static func counts(done: Int, total: Int) -> String {
        "\(min(max(done, 0), max(total, 0)).formatted()) of \(max(total, 0).formatted())"
    }

    /// Throughput and time left, then where it is. A long job that only says
    /// how far along it is cannot answer "is it supposed to be this slow?" —
    /// the rate and the ETA are what make that judgeable.
    static func pace(rate: Double, eta: TimeInterval?, place: String?) -> String? {
        var parts: [String] = []
        if rate >= 0.05 { parts.append(rate >= 10 ? "\(Int(rate.rounded()))/s"
                                                  : String(format: "%.1f/s", rate)) }
        if let eta, let text = duration(eta) { parts.append("~\(text) left") }
        if let place, !place.isEmpty { parts.append(place) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Coarse on purpose: "~3h" is actionable, "2h 58m 14s" is false precision
    /// for a rate that swings whenever the user starts browsing.
    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let s = Int(seconds.rounded())
        if s < 90 { return "\(max(s, 1))s" }
        if s < 5_400 { return "\(Int((Double(s) / 60).rounded()))m" }
        let hours = Double(s) / 3600
        return hours < 10 ? String(format: "%.1fh", hours) : "\(Int(hours.rounded()))h"
    }
}
