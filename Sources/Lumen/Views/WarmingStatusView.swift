import SwiftUI

/// Tiny status-bar view that shows background thumbnail-warming progress.
/// It observes `WarmingMonitor` directly, so the frequent progress ticks only
/// re-render this label — never the grid or sidebar.
struct WarmingStatusView: View {
    @ObservedObject var warming: WarmingMonitor

    var body: some View {
        if warming.remaining > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Building thumbnail cache in the background for instant browsing")
            }
        }
    }

    private var text: String {
        if let folder = warming.folder { return "Caching \(warming.remaining) · \(folder)" }
        return "Caching \(warming.remaining)"
    }
}
