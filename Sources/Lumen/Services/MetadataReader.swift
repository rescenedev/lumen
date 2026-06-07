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

    var hasCameraInfo: Bool {
        cameraMake != nil || cameraModel != nil || lens != nil ||
        aperture != nil || shutterSpeed != nil || iso != nil || focalLength != nil
    }
}

/// Reads EXIF/TIFF/GPS metadata from an image file using ImageIO.
enum MetadataReader {
    static func read(url: URL) -> ImageMetadata {
        var meta = ImageMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return meta }

        meta.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        meta.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        meta.colorModel = props[kCGImagePropertyColorModel] as? String
        if let dpi = props[kCGImagePropertyDPIWidth] as? Int { meta.dpi = dpi }

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
