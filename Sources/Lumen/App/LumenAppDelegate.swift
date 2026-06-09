import AppKit

/// Keeps the app alive when the last window closes so background work —
/// thumbnail-cache warming in particular — can continue at a trickle.
/// ⌘Q still quits and stops everything.
final class LumenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowsChanged),
                           name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowsChanged),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // window closed ≠ quit: warming continues (slowly) in the background
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true    // Dock click with no windows → SwiftUI reopens the WindowGroup
    }

    /// No visible window → warm at a trickle (<1% CPU); window back → full pace.
    /// Deferred a turn so the closing window is already out of `NSApp.windows`.
    @objc private func windowsChanged(_ note: Notification) {
        DispatchQueue.main.async {
            let anyVisible = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
            ThumbnailCache.shared.setTrickleMode(!anyVisible)
        }
    }
}
