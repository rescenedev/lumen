import SwiftUI

/// Holds the background thumbnail-warming progress in its OWN observable object,
/// separate from AppModel. Frequent progress ticks then only re-render the small
/// status view that observes this — not the grid or sidebar.
@MainActor
final class WarmingMonitor: ObservableObject {
    /// Thumbnails still to build in this pass.
    @Published private(set) var remaining = 0
    /// The size of this pass's work list. A bare countdown ("Caching 29,412")
    /// tells the user nothing about how far along they are — the denominator is
    /// what makes the number mean something.
    @Published private(set) var total = 0
    /// Full path of the photo being decoded right now, so the detail popover
    /// can answer "where exactly is it reading?".
    @Published private(set) var currentPath: String?

    /// Thumbnails finished in this pass.
    var done: Int { max(0, total - remaining) }
    /// 0…1, or 0 before a total is known — safe to hand to a determinate bar.
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    /// Just the enclosing folder — what the one-line status row has room for.
    var folder: String? {
        guard let currentPath else { return nil }
        return ((currentPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    func update(remaining: Int, total: Int, currentPath: String?) {
        // A late tick from a superseded pass can carry a bigger remaining than
        // its own total; clamp so the bar can never run backwards past full.
        self.total = max(total, remaining)
        self.remaining = remaining
        self.currentPath = currentPath
    }
}
