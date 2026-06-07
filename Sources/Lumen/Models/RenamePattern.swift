import Foundation

/// Pure filename-pattern expansion for batch rename. `{n}` is replaced with a
/// sequential number. Kept separate (and side-effect free) so both the rename
/// action and its live preview share one implementation — and so it's testable.
enum RenamePattern {
    /// The new filename for `index`, re-attaching `ext` if present.
    /// - Parameters:
    ///   - pattern: user pattern, e.g. `"Photo {n}"`.
    ///   - index: sequential number substituted for `{n}`.
    ///   - ext: original extension without the dot (may be empty).
    static func filename(pattern: String, index: Int, ext: String) -> String {
        let base = pattern.replacingOccurrences(of: "{n}", with: String(index))
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}
