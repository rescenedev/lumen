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
    /// One asset, in the shape the caller asked for. Resized needs a real file
    /// to downsample, so it stages the original next to the destination and
    /// removes it again — the alternative is holding a full-size original in
    /// memory for every photo of a 71k-photo library.
    static func export(_ photo: Photo, style: ExportStyle, to directory: URL) async -> Bool {
        switch style {
        case .originals, .zip:
            return await writeOriginal(photo, to: directory) != nil
        case .resized(let maxPixel):
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumenOne-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let original = await writeOriginal(photo, to: tmp) else { return false }
            let staged = Photo(url: original, byteSize: 0,
                               creationDate: photo.creationDate, modificationDate: nil)
            return Exporter.exportResized(staged, maxPixel: maxPixel, to: directory)
        }
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
