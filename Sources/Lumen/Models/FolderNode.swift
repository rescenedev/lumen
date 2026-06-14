import Foundation

/// A node in the hierarchical folder tree shown in the sidebar.
struct FolderNode: Identifiable, Hashable {
    let url: URL
    let name: String
    /// Total photos in this folder and all descendants.
    let count: Int
    var children: [FolderNode]?

    var id: URL { url }

    // Hash by url (the node identity) only. The synthesized hash would recurse
    // through the entire `children` subtree — O(subtree) per node on a large
    // tree. `==` stays synthesized (structural); equal nodes share a url, so
    // their hashes remain consistent.
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
