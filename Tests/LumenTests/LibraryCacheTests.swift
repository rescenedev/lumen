import Foundation
@testable import LumenKit

func libraryCacheTests() {
    test("binaryRoundTripPreservesEveryField") {
        let photos = [
            Photo(url: URL(fileURLWithPath: "/Volumes/data0/photos/2011.Turkey/IMGP4142.jpg"),
                  byteSize: 86137,
                  creationDate: Fixtures.date("2012-10-20T06:48:57Z"),
                  modificationDate: Fixtures.date("2011-07-23T16:48:44Z")),
            Photo(url: URL(fileURLWithPath: "/Users/x/Desktop/한글 폴더/사진 (1).HEIC"),
                  byteSize: 0, creationDate: nil, modificationDate: nil),
        ]
        let decoded = LibraryCache.decodePhotosBinary(LibraryCache.encodePhotosBinary(photos))
        checkEqual(decoded?.count, 2)
        for (a, b) in zip(photos, decoded ?? []) {
            checkEqual(a.url, b.url)
            checkEqual(a.filename, b.filename)
            checkEqual(a.fileExtension, b.fileExtension)
            checkEqual(a.byteSize, b.byteSize)
            checkEqual(a.creationDate, b.creationDate)
            checkEqual(a.modificationDate, b.modificationDate)
        }
    }

    test("binaryRejectsGarbageAndTruncation") {
        checkEqual(LibraryCache.decodePhotosBinary(Data()), nil)
        checkEqual(LibraryCache.decodePhotosBinary(Data([0x00, 0x01, 0x02, 0x03, 0x04])), nil)
        let valid = LibraryCache.encodePhotosBinary([
            Photo(url: URL(fileURLWithPath: "/a/b.jpg"), byteSize: 1, creationDate: nil, modificationDate: nil)
        ])
        checkEqual(LibraryCache.decodePhotosBinary(valid.prefix(valid.count - 4)), nil)
    }

    test("binaryEmptyListDecodesAsNil") {
        // An empty cache is indistinguishable from "no cache" — loaders fall
        // back to a rescan either way.
        checkEqual(LibraryCache.decodePhotosBinary(LibraryCache.encodePhotosBinary([])), nil)
    }
}
