import Foundation
@testable import LumenKit

/// Regression tests for the sidebar folder-tree click behaviour.
///
/// BUG: clicking a folder row opened the tree then immediately collapsed it
/// (intermittently). Root cause: the row click ran a *toggle* of the folder's
/// expansion 50ms later, which raced with a second toggle (a duplicate
/// mouse-down, or the native disclosure control) and flipped an open folder
/// shut. Fix: a row click is *expand-only* — it reveals a collapsed folder but
/// never collapses one. Collapsing is the chevron's / ← key's job, so a stray
/// second event can no longer close what the click just opened.
func folderClickExpansionTests() {
    let a = URL(filePath: "/lib/a", directoryHint: .isDirectory)
    let b = URL(filePath: "/lib/b", directoryHint: .isDirectory)

    test("folder click expands a collapsed folder") {
        let result = FolderTreeExpansion.expandedAfterFolderClick(
            current: [], before: [], clicked: a)
        check(result.contains(a), "click should reveal the collapsed folder's children")
    }

    test("folder click on an already-expanded folder is a no-op (never collapses)") {
        // The core bug: a duplicate mouse-down / late native toggle re-runs the
        // decision with the folder already open. Expand-only must keep it open.
        let result = FolderTreeExpansion.expandedAfterFolderClick(
            current: [a], before: [a], clicked: a)
        check(result.contains(a), "an open folder must stay open after a row click")
        checkEqual(result, [a])
    }

    test("folder click leaves expansion unchanged when it shifted since the click (chevron)") {
        // If the disclosure chevron collapsed the folder mid-flight, `before`
        // no longer matches `current` — don't fight the native control by
        // re-expanding it.
        let result = FolderTreeExpansion.expandedAfterFolderClick(
            current: [], before: [a], clicked: a)
        check(!result.contains(a), "must not re-expand a folder the chevron just collapsed")
        checkEqual(result, [])
    }

    test("folder click preserves other folders' expansion state") {
        let result = FolderTreeExpansion.expandedAfterFolderClick(
            current: [b], before: [b], clicked: a)
        check(result.contains(a) && result.contains(b),
              "clicking a must expand it without touching b")
    }
}
