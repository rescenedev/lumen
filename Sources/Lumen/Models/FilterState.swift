import Foundation

/// Active, user-controlled filters applied on top of the sidebar scope.
struct FilterState: Equatable, Hashable, Sendable {
    var fileType: String? = nil       // lowercased extension, e.g. "jpg"
    var minRating: Int = 0            // 0 = any
    var label: ColorLabel? = nil
    var favoritesOnly: Bool = false
    var gpsOnly: Bool = false
    var camera: String? = nil

    var isActive: Bool {
        fileType != nil || minRating > 0 || label != nil ||
        favoritesOnly || gpsOnly || camera != nil
    }

    /// Human-readable chips describing the active filters.
    var chips: [String] {
        var result: [String] = []
        if let fileType { result.append(fileType.uppercased()) }
        if minRating > 0 { result.append("★ \(minRating)+") }
        if let label, let _ = label.color { result.append(label.title) }
        if favoritesOnly { result.append("Favorites") }
        if gpsOnly { result.append("Has Location") }
        if let camera { result.append(camera) }
        return result
    }

    static let none = FilterState()
}
