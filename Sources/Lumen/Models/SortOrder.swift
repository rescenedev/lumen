import Foundation

/// How the photo grid is ordered.
enum SortOrder: String, CaseIterable, Identifiable {
    case dateNewest = "Date (Newest)"
    case dateOldest = "Date (Oldest)"
    case nameAZ = "Name (A–Z)"
    case nameZA = "Name (Z–A)"
    case sizeLargest = "Size (Largest)"
    case sizeSmallest = "Size (Smallest)"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dateNewest, .dateOldest: return "calendar"
        case .nameAZ, .nameZA: return "textformat"
        case .sizeLargest, .sizeSmallest: return "externaldrive"
        }
    }

    /// Comparator used to sort an array of photos.
    func sorted(_ photos: [Photo]) -> [Photo] {
        switch self {
        case .dateNewest:
            return photos.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .dateOldest:
            return photos.sorted { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }
        case .nameAZ:
            return photos.sorted {
                let c = $0.filename.localizedStandardCompare($1.filename)
                // Tie-break on full path so equal filenames sort deterministically.
                return c == .orderedSame ? $0.url.path < $1.url.path : c == .orderedAscending
            }
        case .nameZA:
            return photos.sorted {
                let c = $0.filename.localizedStandardCompare($1.filename)
                return c == .orderedSame ? $0.url.path < $1.url.path : c == .orderedDescending
            }
        case .sizeLargest:
            return photos.sorted { $0.byteSize > $1.byteSize }
        case .sizeSmallest:
            return photos.sorted { $0.byteSize < $1.byteSize }
        }
    }
}
