import Foundation

/// A node in the hierarchical folder tree shown in the sidebar.
struct FolderNode: Identifiable, Hashable {
    let url: URL
    let name: String
    /// Total photos in this folder and all descendants.
    let count: Int
    var children: [FolderNode]?

    var id: URL { url }
}
