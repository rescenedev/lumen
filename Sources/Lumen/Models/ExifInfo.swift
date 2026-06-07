import Foundation

/// A compact, indexable subset of a photo's EXIF, computed in the background
/// for every photo so that filtering, search, and the map can be instant.
struct ExifInfo: Sendable, Equatable, Codable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var cameraMake: String?
    var cameraModel: String?
    var dateTaken: Date?
    var latitude: Double?
    var longitude: Double?

    var hasGPS: Bool { latitude != nil && longitude != nil }

    /// Combined "Make Model" for display, search, and filtering (e.g.
    /// "SONY ILCE-7CM2"), avoiding duplication when the model already
    /// includes the make.
    var cameraDisplay: String? {
        switch (cameraMake, cameraModel) {
        case let (make?, model?):
            return model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
        case let (make?, nil): return make
        case let (nil, model?): return model
        default: return nil
        }
    }
}
