import Foundation

/// Wire format between Lumen and the `lumen-meta-bg` helper process.
///
/// Requests go in as NUL-separated paths: a filename may legally contain a
/// newline, never a NUL, so this is the only separator that can't be forged by
/// a file on the user's disk.
///
/// Replies come back one JSON object per line. JSON escapes newlines, so line
/// framing is safe in that direction, and it lets the parent consume results
/// as they arrive instead of waiting for the whole chunk.
enum MetadataHelper {
    /// The helper's name inside `Lumen.app/Contents/MacOS/`.
    static let executableName = "lumen-meta-bg"

    /// One photo's result. Short keys because this crosses a pipe once per
    /// photo, ~100k times for a full pass.
    struct Reply: Codable, Equatable {
        var p: String              // path
        var w: Int?                // pixel width
        var h: Int?                // pixel height
        var mk: String?            // camera make
        var md: String?            // camera model
        var dt: Double?            // date taken, epoch seconds
        var lat: Double?
        var lon: Double?
        /// Non-nil when the file could not be read at all. Distinct from "read
        /// fine, carries no EXIF", which is every field nil and `e` nil.
        var e: String?

        var info: ExifInfo {
            var i = ExifInfo()
            i.pixelWidth = w
            i.pixelHeight = h
            i.cameraMake = mk
            i.cameraModel = md
            i.dateTaken = dt.map { Date(timeIntervalSince1970: $0) }
            i.latitude = lat
            i.longitude = lon
            return i
        }

        init(path: String, info: ExifInfo, failure: String?) {
            p = path
            w = info.pixelWidth
            h = info.pixelHeight
            mk = info.cameraMake
            md = info.cameraModel
            dt = info.dateTaken?.timeIntervalSince1970
            lat = info.latitude
            lon = info.longitude
            e = failure
        }
    }

    static func encode(_ reply: Reply) -> Data? {
        guard var data = try? JSONEncoder().encode(reply) else { return nil }
        data.append(0x0A)   // newline terminator — the frame boundary
        return data
    }

    static func decode(line: Data) -> Reply? {
        guard !line.isEmpty else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: line)
    }

    /// Split a stdout buffer into complete lines, returning the leftover tail
    /// so the caller can prepend it to the next read. A pipe read can land
    /// mid-object; treating a partial line as a frame would drop that photo.
    static func lines(from buffer: inout Data) -> [Data] {
        var out: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            out.append(buffer[buffer.startIndex..<index])
            buffer = buffer[(index + 1)...]
        }
        return out
    }

    /// Encode a request: NUL-separated, NUL-terminated.
    static func encodeRequest(_ paths: [String]) -> Data {
        var data = Data()
        for path in paths {
            data.append(contentsOf: Array(path.utf8))
            data.append(0x00)
        }
        return data
    }

    /// The mirror of `encodeRequest`, used by the helper.
    static func decodeRequest(_ data: Data) -> [String] {
        data.split(separator: 0x00, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
