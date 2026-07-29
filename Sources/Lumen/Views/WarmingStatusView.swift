import SwiftUI

/// Tiny status-bar view that shows background thumbnail-warming progress.
/// It observes `WarmingMonitor` directly, so the frequent progress ticks only
/// re-render this label — never the grid or sidebar.
struct WarmingStatusView: View {
    @ObservedObject var warming: WarmingMonitor

    var body: some View {
        if warming.remaining > 0 {
            HStack(spacing: 6) {
                // Determinate: the work list size is known up front, so show
                // real headway instead of an indeterminate spinner.
                ProgressView(value: warming.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 70)
                Text(BackgroundWorkText.warming(done: warming.done, total: warming.total,
                                                folder: warming.folder))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help("Building the thumbnail cache in the background so browsing is instant. "
                          + "Photos stay usable while this runs.")
            }
        }
    }
}

/// Pure status-line wording for the two long background jobs, kept out of the
/// views so the phrasing is unit-tested and consistent.
enum BackgroundWorkText {
    /// Thumbnail warming: the total is known, so always show the fraction.
    static func warming(done: Int, total: Int, folder: String?) -> String {
        var text = "Thumbnails \(done.formatted()) / \(total.formatted())"
        if total > 0 {
            text += " · \(Int((Double(done) / Double(total) * 100).rounded()))%"
        }
        if let folder, !folder.isEmpty { text += " · \(folder)" }
        return text
    }
}
