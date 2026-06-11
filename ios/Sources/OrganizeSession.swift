import Foundation

/// One organize run's decisions + undo history. Pure logic (no PhotoKit, no UI)
/// so it's unit-testable — OrganizeView owns one and replays undone actions'
/// side effects (Lumen album, favorite state) itself.
struct OrganizeSession {
    enum Decision: Equatable { case keep, trash }

    /// Everything undo needs to revert one user action.
    enum Action: Equatable {
        case decide(index: Int, decision: Decision, previous: Decision?)
        case favorite(index: Int, assetID: String, wasFavorite: Bool)

        /// The photo the action happened on — undo jumps the viewer back to it.
        var index: Int {
            switch self {
            case .decide(let i, _, _), .favorite(let i, _, _): i
            }
        }
    }

    private(set) var decisions: [Int: Decision] = [:]
    private(set) var history: [Action] = []

    var canUndo: Bool { !history.isEmpty }
    var keepCount: Int { decisions.values.filter { $0 == .keep }.count }
    var trashIndices: [Int] { decisions.compactMap { $0.value == .trash ? $0.key : nil } }

    func decision(at index: Int) -> Decision? { decisions[index] }

    mutating func decide(_ d: Decision, at index: Int) {
        history.append(.decide(index: index, decision: d, previous: decisions[index]))
        decisions[index] = d
    }

    /// Favorites don't affect decisions — recorded only so they can be undone.
    mutating func recordFavorite(at index: Int, assetID: String, wasFavorite: Bool) {
        history.append(.favorite(index: index, assetID: assetID, wasFavorite: wasFavorite))
    }

    /// Pop the most recent action, restoring the decision table; returns the
    /// action so the caller can revert its side effects too.
    mutating func undo() -> Action? {
        guard let action = history.popLast() else { return nil }
        if case .decide(let i, _, let previous) = action {
            if let previous { decisions[i] = previous } else { decisions.removeValue(forKey: i) }
        }
        return action
    }
}
