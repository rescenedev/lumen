import Foundation
import SwiftUI

/// Thread-safe cancel flag for one import, and that import's identity. The
/// scanner polls it from its own (background) thread while the UI flips it on
/// the main actor, so it can't be a plain Bool on the model.
final class ScanCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}

/// Live progress of a folder import, in its OWN observable object — same reason
/// as `WarmingMonitor`: the scan publishes a few times a second and must only
/// re-render the small status view, never the grid or sidebar.
///
/// Every mutator takes the token `begin()` handed out, so a finishing import
/// can't clobber the display of a newer one that started while it was still
/// wrapping up (EXIF indexing, cache writes).
@MainActor
final class ScanMonitor: ObservableObject {
    /// A scan is walking the filesystem right now.
    @Published private(set) var isScanning = false
    /// Photos the walk has found so far (including ones already in the library).
    @Published private(set) var found = 0
    /// Photos actually added to the library so far — what the user cares about.
    @Published private(set) var added = 0
    /// The folder currently being read, for a sense of where the walk is.
    @Published private(set) var folder: String?
    /// The user asked to stop; the walk finishes its current folder and returns.
    @Published private(set) var isStopping = false

    // Not @Published — the view never reads it, only the scanner thread does.
    private var current: ScanCancelToken?

    /// Take ownership of the display and hand back the token the scanner polls.
    func begin() -> ScanCancelToken {
        let token = ScanCancelToken()
        current = token
        isScanning = true
        isStopping = false
        found = 0
        added = 0
        folder = nil
        return token
    }

    func update(_ token: ScanCancelToken, found: Int, folder: String?) {
        guard token === current else { return }
        self.found = found
        self.folder = folder
    }

    func addedPhotos(_ token: ScanCancelToken, _ count: Int) {
        guard token === current else { return }
        added += count
    }

    /// Stop the import that currently owns the display.
    func cancel() {
        guard isScanning, !isStopping, let current else { return }
        isStopping = true
        current.cancel()
    }

    /// Idempotent, and a no-op once a newer scan has taken over.
    func finish(_ token: ScanCancelToken) {
        guard token === current else { return }
        current = nil
        isScanning = false
        isStopping = false
        folder = nil
    }
}
