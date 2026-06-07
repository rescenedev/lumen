import Foundation

/// A user-created album: an ordered set of photo paths.
struct Album: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var photoPaths: [String]

    init(id: UUID = UUID(), name: String, photoPaths: [String] = []) {
        self.id = id
        self.name = name
        self.photoPaths = photoPaths
    }
}
