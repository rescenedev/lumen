import Foundation

/// Adapts an Apple Photos (PhotoKit) asset into the file-URL-shaped `Photo`
/// model by wrapping its `localIdentifier` in a synthetic `photos-library://`
/// URL. This lets selection, the grid, the viewer, metadata, and caching — all
/// keyed by URL — work unchanged; only image decoding and destructive ops branch
/// on `isAsset`. See docs/design/photos-library.md.
extension Photo {
    static let assetScheme = "photos-library"

    /// Build a `Photo` backed by a PhotoKit asset.
    ///
    /// URL shape: `photos-library:///<percent-encoded localIdentifier>/<dateLabel>`
    /// - The id is the first path segment, recovered from `absoluteString` (which
    ///   preserves its percent-encoding, so an embedded `/` in the id survives).
    /// - The date label is the last segment, so `filename` (= `lastPathComponent`)
    ///   shows something human-readable in the grid caption and name sort.
    static func asset(localIdentifier: String,
                      creationDate: Date?,
                      modificationDate: Date?) -> Photo {
        let encodedId = localIdentifier
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? localIdentifier
        let label = assetDateLabel(creationDate)
        let url = URL(string: "\(assetScheme):///\(encodedId)/\(label)")
            ?? URL(string: "\(assetScheme):///\(encodedId)")!
        return Photo(url: url, byteSize: 0, creationDate: creationDate, modificationDate: modificationDate)
    }

    /// True when this Photo is backed by a Photos-library asset (no real file).
    var isAsset: Bool { url.scheme == Photo.assetScheme }

    /// The PhotoKit `localIdentifier`, recovered from the synthetic URL.
    var assetLocalIdentifier: String? { url.photosAssetLocalIdentifier }

    /// A URL-safe, human-readable label (no spaces/separators) for the caption.
    static func assetDateLabel(_ date: Date?) -> String {
        guard let date else { return "Photo" }
        return assetLabelFormatter.string(from: date)
    }

    private static let assetLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}

extension URL {
    /// The PhotoKit `localIdentifier` if this is a synthetic `photos-library://`
    /// asset URL, else nil. Parsed from `absoluteString` (which preserves the
    /// id's percent-encoding, so an embedded `/` survives the round-trip).
    var photosAssetLocalIdentifier: String? {
        guard scheme == Photo.assetScheme else { return nil }
        let prefix = "\(Photo.assetScheme):///"
        let s = absoluteString
        guard s.hasPrefix(prefix) else { return nil }
        let rest = s.dropFirst(prefix.count)
        let firstSegment = rest.split(separator: "/", maxSplits: 1,
                                      omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return firstSegment.removingPercentEncoding
    }
}
