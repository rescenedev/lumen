import Foundation

/// Materializes iCloud "dataless" files (Optimize Mac Storage / Desktop &
/// Documents in iCloud) on demand. A local file is returned untouched.
enum iCloudDownloader {
    /// True if the URL is an iCloud item whose data is not yet downloaded.
    static func isDataless(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]), values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// Trigger a download and block (up to `timeout`) until the data is local.
    /// Safe to call on a background queue; never call on the main thread.
    @discardableResult
    static func ensureLocal(_ url: URL, timeout: TimeInterval = 25) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]), values.isUbiquitousItem == true else {
            return true // ordinary local file
        }
        if values.ubiquitousItemDownloadingStatus == .current { return true }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus, status == .current {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
