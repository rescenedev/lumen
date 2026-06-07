import SwiftUI

/// Finder-style color labels.
enum ColorLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, blue, purple, gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        default: return rawValue.capitalized
        }
    }

    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    var nsColor: NSColor? {
        switch self {
        case .none: return nil
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }
}

/// Per-photo user metadata that Lumen owns (the files themselves are untouched).
struct PhotoMeta: Codable, Equatable, Sendable {
    var favorite: Bool = false
    var rating: Int = 0            // 0...5
    var label: ColorLabel = .none
    var tags: [String] = []

    var isEmpty: Bool {
        !favorite && rating == 0 && label == .none && tags.isEmpty
    }
}
