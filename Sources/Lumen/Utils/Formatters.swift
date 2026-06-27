import Foundation

/// Shared, lazily-created formatters for the UI.
enum Format {
    static let byteCount: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func size(_ bytes: Int64) -> String {
        byteCount.string(fromByteCount: bytes)
    }

    static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        // Reuse the cached DateFormatter (.medium/.short renders identically to
        // .abbreviated/.shortened). Date.formatted() builds a fresh FormatStyle
        // per call — ~10-50x slower, and the table date column calls this per
        // visible row on every scroll frame.
        return Format.date.string(from: date)
    }

    static func dimensions(_ width: Int?, _ height: Int?) -> String {
        guard let width, let height else { return "—" }
        return "\(width) × \(height)"
    }

    static func megapixels(_ width: Int?, _ height: Int?) -> String? {
        guard let width, let height else { return nil }
        let mp = Double(width) * Double(height) / 1_000_000
        return mp >= 0.1 ? String(format: "%.1f MP", mp) : nil
    }
}
