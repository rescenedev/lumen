import SwiftUI

/// Tiny status-bar view that shows background thumbnail-warming progress.
/// It observes `WarmingMonitor` directly, so the frequent progress ticks only
/// re-render this label — never the grid or sidebar.
struct WarmingStatusView: View {
    @ObservedObject var warming: WarmingMonitor

    var body: some View {
        if warming.remaining > 0 {
            StatusRow(label: "Thumbnails",
                      detail: BackgroundWorkText.counts(done: warming.done, total: warming.total),
                      context: warming.folder) {
                ThinProgressBar(fraction: warming.fraction)
            }
            .help("Building the thumbnail cache in the background so browsing is instant. "
                  + "Your photos stay usable while this runs.")
        }
    }
}

/// Pure status-line wording for the long background jobs, kept out of the views
/// so the phrasing is unit-tested and consistent between them.
enum BackgroundWorkText {
    /// Always a fraction. A bare countdown ("Caching 29,412") is a number with
    /// nothing to measure it against. No percentage: the bar already says what
    /// share is done, and printing it twice is clutter, not clarity.
    static func counts(done: Int, total: Int) -> String {
        "\(done.formatted()) of \(total.formatted())"
    }
}
