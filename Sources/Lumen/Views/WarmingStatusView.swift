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
                          context: warming.folder,
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
}
