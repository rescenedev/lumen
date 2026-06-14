import Foundation
import ImageIO
import CoreLocation

/// A single labelled metadata row for the inspector.
struct MetadataRow: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
}

/// Decoded image metadata grouped for display.
struct ImageMetadata: Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var colorModel: String?
    var dpi: Int?

    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var focalLength: String?
    var aperture: String?
    var shutterSpeed: String?
    var iso: String?
    var dateTaken: String?

    var gpsCoordinate: (lat: Double, lon: Double)?

    // Set for Photos-library assets, whose info comes from PhotoKit rather than a
    // file on disk (the synthetic URL has no real extension/size/path).
    var byteSize: Int64?
    var kind: String?
    var sourceLabel: String?   // shown in "Where" for assets, e.g. "Apple Photos"

    var hasCameraInfo: Bool {
        cameraMake != nil || cameraModel != nil || lens != nil ||
        aperture != nil || shutterSpeed != nil || iso != nil || focalLength != nil
    }
}

/// Reads EXIF/TIFF/GPS metadata from an image file using ImageIO.
enum MetadataReader {
    static func read(url: URL) -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return ImageMetadata() }
        return parse(props)
    }

    /// Parse metadata from already-decoded image data (e.g. PhotoKit-supplied
    /// asset data), reusing the same property parsing as the file path.
    static func read(data: Data) -> ImageMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return ImageMetadata() }
        return parse(props)
    }

    /// Extract EXIF/TIFF/GPS fields from a CGImageSource property dictionary.
    static func parse(_ props: [CFString: Any]) -> ImageMetadata {
        var meta = ImageMetadata()
        // Via NSNumber: `as? Int` returns nil for a float-backed CFNumber
        // (e.g. a DPI of 96.5), silently dropping the value.
        meta.pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        meta.pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        meta.colorModel = props[kCGImagePropertyColorModel] as? String
        if let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue { meta.dpi = dpi }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            meta.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            meta.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let lens = exif[kCGImagePropertyExifLensModel] as? String { meta.lens = lens }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                meta.focalLength = String(format: "%.0f mm", focal)
            }
            if let fnum = exif[kCGImagePropertyExifFNumber] as? Double {
                meta.aperture = String(format: "ƒ/%.1f", fnum)
            }
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
                meta.shutterSpeed = exposure < 1
                    ? "1/\(Int((1 / exposure).rounded())) s"
                    : String(format: "%.1f s", exposure)
            }
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArray.first {
                meta.iso = "ISO \(iso)"
            }
            meta.dateTaken = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            meta.gpsCoordinate = (
                lat: latRef == "S" ? -lat : lat,
                lon: lonRef == "W" ? -lon : lon
            )
        }
        return meta
    }
}
