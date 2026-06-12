import Foundation

/// One reversible metadata-organizing action (rate, favorite, label, tag,
/// reject) recorded in the history timeline. The photo files are never part
/// of this — only Lumen-owned metadata, so reverting can't lose a photo.
struct OperationLogEntry: Identifiable, Equatable, Sendable {
    let id: Int64
    let date: Date
    let kind: Kind
    let summary: String       // e.g. "★4 · 12 photos"
    let affectedCount: Int
    var undone: Bool

    enum Kind: String, Sendable {
        case favorite, rating, label, tag, reject, other

        var symbol: String {
            switch self {
            case .favorite: return "heart.fill"
            case .rating:   return "star.fill"
            case .label:    return "tag.fill"
            case .tag:      return "number"
            case .reject:   return "xmark.bin.fill"
            case .other:    return "clock.arrow.circlepath"
            }
        }
    }
}
