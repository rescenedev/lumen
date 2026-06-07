import AppKit
import QuickLookUI

/// Presents the system Quick Look panel for a photo (triggered by the spacebar).
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()

    private var urls: [URL] = []
    private var startIndex = 0

    func show(urls: [URL], startAt index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        self.startIndex = max(0, min(index, urls.count - 1))
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = startIndex
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle(urls: [URL], startAt index: Int) {
        if let panel = QLPreviewPanel.shared(), QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(urls: urls, startAt: index)
        }
    }

    // MARK: QLPreviewPanelDataSource
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
