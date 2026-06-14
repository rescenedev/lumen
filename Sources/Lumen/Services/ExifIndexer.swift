import Foundation
import ImageIO

/// Computes compact `ExifInfo` for photos off the main thread so filtering,
/// search, and the map don't pay a decode cost at query time.
enum ExifIndexer {
    /// Index the given files, returning a [path: ExifInfo] map. Designed to run
    /// inside a detached background task. Reads serially on purpose — the NAS is
    /// the bottleneck (parallelism barely helped in testing) and a serial pass at
    /// background priority keeps the index from spiking CPU or stealing I/O from
    /// the foreground while the user browses.
    static func index(_ urls: [URL]) -> [String: ExifInfo] {
        var result: [String: ExifInfo] = [:]
        result.reserveCapacity(urls.count)
        for url in urls {
            result[url.path] = read(url)
        }
        return result
    }

    static func read(_ url: URL) -> ExifInfo {
        var info = ExifInfo()
        // Don't pull whole files out of iCloud just to index them.
        if iCloudDownloader.isDataless(url) { return info }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return info }

        // Via NSNumber.intValue: a plain `as? Int` returns nil for a
        // float-backed CFNumber, silently dropping the dimension.
        info.pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        info.pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            info.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            info.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.dateTaken = Self.exifDateFormatter.date(from: raw)
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           // The ref tags are stored as positive magnitudes' signs; EXIF always
           // pairs them with the coordinate. If a ref is missing we can't know
           // the hemisphere — skip rather than guess N/E and mis-place a
           // Southern/Western photo.
           let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
           let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
            info.latitude = latRef == "S" ? -lat : lat
            info.longitude = lonRef == "W" ? -lon : lon
        }
        return info
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
