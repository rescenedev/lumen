import Foundation
@testable import LumenKit

func renamePatternTests() {
    test("substitutesNumber") {
        checkEqual(RenamePattern.filename(pattern: "Photo {n}", index: 5, ext: "jpg"), "Photo 5.jpg")
    }

    test("emptyExtensionOmitsDot") {
        checkEqual(RenamePattern.filename(pattern: "Photo {n}", index: 1, ext: ""), "Photo 1")
    }

    test("patternWithoutTokenIsLiteral") {
        checkEqual(RenamePattern.filename(pattern: "Vacation", index: 9, ext: "png"), "Vacation.png")
    }

    test("allTokenOccurrencesReplaced") {
        checkEqual(RenamePattern.filename(pattern: "{n}-{n}", index: 3, ext: "heic"), "3-3.heic")
    }

    test("sequenceMatchesPreviewBehavior") {
        // Mirrors how the rename action and the sheet preview number files.
        let start = 1
        let names = (0..<3).map { offset in
            RenamePattern.filename(pattern: "IMG {n}", index: start + offset, ext: "jpg")
        }
        checkEqual(names, ["IMG 1.jpg", "IMG 2.jpg", "IMG 3.jpg"])
    }
}
