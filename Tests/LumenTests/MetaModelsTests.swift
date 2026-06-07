import Foundation
@testable import LumenKit

func photoMetaTests() {
    test("defaultIsEmpty") {
        check(PhotoMeta().isEmpty)
    }

    test("anyFieldMakesItNonEmpty") {
        check(!PhotoMeta(favorite: true).isEmpty)
        check(!PhotoMeta(rating: 1).isEmpty)
        check(!PhotoMeta(label: .red).isEmpty)
        check(!PhotoMeta(tags: ["beach"]).isEmpty)
    }

    test("photoMetaCodableRoundTrip") {
        let meta = PhotoMeta(favorite: true, rating: 4, label: .green, tags: ["a", "b"])
        guard let data = try? JSONEncoder().encode(meta),
              let decoded = try? JSONDecoder().decode(PhotoMeta.self, from: data) else {
            check(false, "encode/decode failed"); return
        }
        checkEqual(meta, decoded)
    }
}

func colorLabelTests() {
    test("titles") {
        checkEqual(ColorLabel.none.title, "None")
        checkEqual(ColorLabel.red.title, "Red")
        checkEqual(ColorLabel.purple.title, "Purple")
    }

    test("noneHasNoColor") {
        checkNil(ColorLabel.none.color)
        checkNil(ColorLabel.none.nsColor)
        checkNotNil(ColorLabel.red.color)
        checkNotNil(ColorLabel.red.nsColor)
    }

    test("rawValueRoundTrip") {
        for label in ColorLabel.allCases {
            check(ColorLabel(rawValue: label.rawValue) == label, "round-trip \(label.rawValue)")
        }
    }

    test("unknownRawValueIsNil") {
        checkNil(ColorLabel(rawValue: "chartreuse"))
    }
}

func albumTests() {
    test("defaults") {
        let album = Album(name: "Trip")
        checkEqual(album.name, "Trip")
        check(album.photoPaths.isEmpty)
    }

    test("idsAreUnique") {
        checkNotEqual(Album(name: "A").id, Album(name: "A").id)
    }

    test("albumCodableRoundTrip") {
        let album = Album(name: "Faves", photoPaths: ["/a.jpg", "/b.jpg"])
        guard let data = try? JSONEncoder().encode(album),
              let decoded = try? JSONDecoder().decode(Album.self, from: data) else {
            check(false, "encode/decode failed"); return
        }
        checkEqual(album, decoded)
    }
}
