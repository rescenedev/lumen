import Foundation
import UniformTypeIdentifiers

/// An immutable description of a single image file on disk.
/// Identity is the file URL, which is unique within a library scan.
struct Photo: Identifiable, Hashable, Sendable, Codable {
    let url: URL
    let filename: String
    let fileExtension: String
    let byteSize: Int64
    let creationDate: Date?
    let modificationDate: Date?

    var id: URL { url }

    /// Parent directory of the file, used to build the folder sidebar.
    var folderURL: URL { url.deletingLastPathComponent() }

    init(url: URL, resourceValues: URLResourceValues) {
        self.url = url
        self.filename = url.lastPathComponent
        self.fileExtension = url.pathExtension.lowercased()
        self.byteSize = Int64(resourceValues.fileSize ?? 0)
        self.creationDate = resourceValues.creationDate
        self.modificationDate = resourceValues.contentModificationDate
    }

    init(url: URL, byteSize: Int64, creationDate: Date?, modificationDate: Date?) {
        self.url = url
        self.filename = url.lastPathComponent
        self.fileExtension = url.pathExtension.lowercased()
        self.byteSize = byteSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    /// A copy of this photo at a new URL (e.g. after a parent folder rename),
    /// preserving size and dates.
    func relocated(to newURL: URL) -> Photo {
        Photo(url: newURL, byteSize: byteSize, creationDate: creationDate, modificationDate: modificationDate)
    }

    /// File types Lumen will scan for and display.
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif",
        "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf",
        "rw2", "raf", "sr2", "psd", "ico", "jp2", "avif"
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
