import Foundation

/// How the library is presented in the detail area.
enum ViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    case map

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        case .map: return "Map"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .map: return "map"
        }
    }
}
