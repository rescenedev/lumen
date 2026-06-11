import XCTest
// OrganizeSession.swift is compiled into this test bundle directly (see
// project.yml), so it's in-module — pure logic, no PhotoKit needed.
final class OrganizeSessionTests: XCTestCase {

    func testDecideMarksAndCounts() {
        var s = OrganizeSession()
        s.decide(.keep, at: 0)
        s.decide(.trash, at: 1)
        s.decide(.trash, at: 5)
        XCTAssertEqual(s.decision(at: 0), .keep)
        XCTAssertEqual(s.keepCount, 1)
        XCTAssertEqual(s.trashIndices.sorted(), [1, 5])
        XCTAssertTrue(s.canUndo)
    }

    func testRedecideReplacesDecision() {
        var s = OrganizeSession()
        s.decide(.keep, at: 3)
        s.decide(.trash, at: 3)
        XCTAssertEqual(s.decision(at: 3), .trash)
        XCTAssertEqual(s.keepCount, 0)
        XCTAssertEqual(s.trashIndices, [3])
    }

    func testUndoRemovesFreshDecision() {
        var s = OrganizeSession()
        s.decide(.trash, at: 2)
        let undone = s.undo()
        XCTAssertEqual(undone, .decide(index: 2, decision: .trash, previous: nil))
        XCTAssertNil(s.decision(at: 2))
        XCTAssertFalse(s.canUndo)
    }

    func testUndoRestoresPreviousDecision() {
        var s = OrganizeSession()
        s.decide(.keep, at: 4)
        s.decide(.trash, at: 4)      // changed their mind…
        _ = s.undo()                 // …then undid the change
        XCTAssertEqual(s.decision(at: 4), .keep)
        XCTAssertEqual(s.keepCount, 1)
        XCTAssertTrue(s.trashIndices.isEmpty)
    }

    func testUndoIsLIFO() {
        var s = OrganizeSession()
        s.decide(.keep, at: 0)
        s.decide(.trash, at: 1)
        XCTAssertEqual(s.undo()?.index, 1)
        XCTAssertEqual(s.undo()?.index, 0)
        XCTAssertNil(s.undo())
    }

    func testFavoriteIsRecordedButDoesNotTouchDecisions() {
        var s = OrganizeSession()
        s.recordFavorite(at: 7, assetID: "A", wasFavorite: false)
        XCTAssertNil(s.decision(at: 7))
        XCTAssertEqual(s.keepCount, 0)
        XCTAssertTrue(s.canUndo)
        XCTAssertEqual(s.undo(), .favorite(index: 7, assetID: "A", wasFavorite: false))
        XCTAssertFalse(s.canUndo)
    }

    func testUndoOnEmptyReturnsNil() {
        var s = OrganizeSession()
        XCTAssertNil(s.undo())
        XCTAssertFalse(s.canUndo)
    }

    func testMixedFlowUndoesInOrder() {
        var s = OrganizeSession()
        s.decide(.trash, at: 0)
        s.recordFavorite(at: 1, assetID: "B", wasFavorite: true)
        s.decide(.keep, at: 2)
        _ = s.undo()                                  // un-keep 2
        XCTAssertNil(s.decision(at: 2))
        _ = s.undo()                                  // un-favorite 1
        XCTAssertEqual(s.trashIndices, [0])           // trash on 0 still stands
        _ = s.undo()                                  // un-trash 0
        XCTAssertTrue(s.trashIndices.isEmpty)
        XCTAssertFalse(s.canUndo)
    }
}
