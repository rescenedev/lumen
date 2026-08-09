import Foundation
import Photos
import UniformTypeIdentifiers

/// Exporting photos that live in Apple Photos rather than on disk.
///
/// The file-based `Exporter` reads `photo.url`, and an asset's URL is synthetic
/// (`photos-library:///<localIdentifier>`) — there is nothing there to open. So
/// the Export menu quietly did nothing for anything in the Photos library. This
/// writes the real bytes out of PhotoKit, which is also the only path that can
/// pull down an asset stored only in iCloud.
enum PhotosExporter {
    /// Write each asset's ORIGINAL file straight into `directory`, under the
    /// name it has in Photos. Returns how many landed.
    static func writeOriginals(_ photos: [Photo], to directory: URL) async -> Int {
        var written = 0
        for photo in photos where photo.isAsset {
            if await writeOriginal(photo, to: directory) != nil { written += 1 }
        }
        return written
    }

    /// Materialise assets as real files in a temporary directory so the shared
    /// resize/zip paths can treat them like any other photo. The caller MUST
    /// call `cleanup` — these are full-size originals, easily gigabytes.
    static func stage(_ photos: [Photo]) async -> (photos: [Photo], cleanup: @Sendable () -> Void) {
        let assets = photos.filter { $0.isAsset }
        guard !assets.isEmpty else { return ([], {}) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenExport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var staged: [Photo] = []
        for photo in assets {
            guard let url = await writeOriginal(photo, to: dir) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            staged.append(Photo(url: url,
                                byteSize: Int64(values?.fileSize ?? 0),
                                // Keep the capture date so a resized export
                                // still sorts and dates like the original.
                                creationDate: photo.creationDate,
                                modificationDate: values?.contentModificationDate))
        }
        return (staged, { try? FileManager.default.removeItem(at: dir) })
    }

    // MARK: -

    /// The resource carrying the original bytes. `.photo` is the untouched
    /// original; an edited asset also has `.fullSizePhoto`, which is the
    /// version the user actually sees, so it wins when present.
    static func preferredResource(_ resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first { $0.type == .fullSizePhoto }
            ?? resources.first { $0.type == .photo }
            ?? resources.first
    }

    private static func writeOriginal(_ photo: Photo, to directory: URL) async -> URL? {
        guard let asset = PhotosImageLoader.shared.phAsset(for: photo.url),
              let resource = preferredResource(PHAssetResource.assetResources(for: asset))
        else { return nil }

        let name = uniqueName(in: directory, preferred: resource.originalFilename)
        let dest = directory.appendingPathComponent(name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // an iCloud-only asset must download

        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: dest, options: options) { error in
                if let error {
                    NSLog("Lumen: export of \(resource.originalFilename) failed: \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: dest)   // no half-written files
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: dest)
                }
            }
        }
    }

    /// Photos allows duplicate filenames (IMG_0001.HEIC many times over);
    /// writeData refuses an existing path, so disambiguate before asking.
    static func uniqueName(in directory: URL, preferred: String,
                           exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
    -> String {
        let base = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        var candidate = preferred
        var counter = 2
        while exists(directory.appendingPathComponent(candidate)) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }
}
