import Foundation

/// A selectable entry in the left sidebar.
enum SidebarItem: Hashable, Identifiable {
    case allPhotos
    case favorites
    case recentlyAdded
    case onThisDay
    case duplicates
    case label(ColorLabel)
    case album(UUID)
    case tag(String)
    case folder(URL)
    case photosLibrary          // Apple Photos / iCloud Photos (PhotoKit)

    var id: String {
        switch self {
        case .allPhotos: return "all"
        case .favorites: return "favorites"
        case .recentlyAdded: return "recent"
        case .onThisDay: return "onThisDay"
        case .duplicates: return "duplicates"
        case .label(let l): return "label:\(l.rawValue)"
        case .album(let uuid): return "album:\(uuid.uuidString)"
        case .tag(let t): return "tag:\(t)"
        case .folder(let url): return "folder:\(url.path)"
        case .photosLibrary: return "photosLibrary"
        }
    }

    var systemImage: String {
        switch self {
        case .allPhotos: return "photo.on.rectangle.angled"
        case .favorites: return "heart.fill"
        case .recentlyAdded: return "clock"
        case .onThisDay: return "calendar"
        case .duplicates: return "square.on.square.dashed"
        case .label: return "circle.fill"
        case .album: return "rectangle.stack"
        case .tag: return "tag"
        case .folder: return "folder"
        case .photosLibrary: return "photo.stack"
        }
    }

    /// True for sources backed by the Apple Photos library rather than files.
    var isPhotosLibrarySource: Bool {
        if case .photosLibrary = self { return true }
        return false
    }
}
