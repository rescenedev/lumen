import Foundation
import SwiftUI

/// Live progress of an export, in its own observable object for the same
/// reason as `WarmingMonitor`: it ticks per photo and must re-render only the
/// status label.
///
/// Exports used to be fire-and-forget with a toast at the end. That was fine
/// for a handful of selected photos and useless for an album — never mind a
/// 71,000-photo Photos library, where every iCloud-only asset downloads first.
/// Hours of work with no count, no way to stop, and no sign it was running.
@MainActor
final class ExportMonitor: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var failed = 0
    /// Filename in flight, so the popover can say where it is.
    @Published private(set) var currentName: String?
    @Published private(set) var isStopping = false
    /// What the user asked for, e.g. "Originals" — the row label.
    @Published private(set) var styleLabel = ""

    private var token = ScanCancelToken()

    var fraction: Double { total > 0 ? Double(min(done, total)) / Double(total) : 0 }

    func begin(total: Int, style: String) -> ScanCancelToken {
        let fresh = ScanCancelToken()
        token = fresh
        isExporting = true
        isStopping = false
        self.total = total
        self.styleLabel = style
        done = 0
        failed = 0
        currentName = nil
        return fresh
    }

    func advance(_ t: ScanCancelToken, name: String?, succeeded: Bool) {
        guard t === token else { return }
        done += 1
        if !succeeded { failed += 1 }
        currentName = name
    }

    func cancel() {
        guard isExporting, !isStopping else { return }
        isStopping = true
        token.cancel()
    }

    /// Idempotent, and a no-op once a newer export owns the display.
    func finish(_ t: ScanCancelToken) {
        guard t === token else { return }
        isExporting = false
        isStopping = false
        currentName = nil
    }
}

/// What an export produces. Kept separate from the UI so the menus, the sidebar
/// and the model all name the same three things.
enum ExportStyle: Equatable, Sendable {
    case originals
    case resized(maxPixel: Int)
    case zip

    var label: String {
        switch self {
        case .originals: return "Originals"
        case .resized(let px): return "Resized \(px)px"
        case .zip: return "Zip"
        }
    }
}
