import SwiftUI

/// Holds the background thumbnail-warming progress in its OWN observable object,
/// separate from AppModel. Frequent progress ticks then only re-render the small
/// status view that observes this — not the grid or sidebar.
@MainActor
final class WarmingMonitor: ObservableObject {
    @Published private(set) var remaining = 0
    @Published private(set) var folder: String?

    func update(remaining: Int, folder: String?) {
        self.remaining = remaining
        self.folder = folder
    }
}
