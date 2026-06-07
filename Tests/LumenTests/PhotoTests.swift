import Foundation
@testable import LumenKit

func photoTests() {
    test("filenameAndExtensionDerivedFromURL") {
        let p = Photo(url: URL(fileURLWithPath: "/a/b/Sunset.JPG"),
                      byteSize: 10, creationDate: nil, modificationDate: nil)
        checkEqual(p.filename, "Sunset.JPG")
        checkEqual(p.fileExtension, "jpg")          // lowercased
        checkEqual(p.folderURL.path, "/a/b")
        checkEqual(p.id, p.url)
    }

    test("isSupportedIsCaseInsensitive") {
        check(Photo.isSupported(URL(fileURLWithPath: "/x/a.jpg")))
        check(Photo.isSupported(URL(fileURLWithPath: "/x/a.JPG")))
        check(Photo.isSupported(URL(fileURLWithPath: "/x/a.heic")))
        check(Photo.isSupported(URL(fileURLWithPath: "/x/a.arw")))   // RAW
        check(Photo.isSupported(URL(fileURLWithPath: "/x/a.dng")))
    }

    test("unsupportedExtensions") {
        check(!Photo.isSupported(URL(fileURLWithPath: "/x/a.txt")))
        check(!Photo.isSupported(URL(fileURLWithPath: "/x/a.mov")))   // video, out of scope
        check(!Photo.isSupported(URL(fileURLWithPath: "/x/noext")))
    }

    test("relocatedKeepsMetadataChangesPath") {
        let date = Fixtures.date("2023-05-05T12:00:00Z")
        let original = Photo(url: URL(fileURLWithPath: "/old/pic.jpg"),
                             byteSize: 4096, creationDate: date, modificationDate: date)
        let moved = original.relocated(to: URL(fileURLWithPath: "/new/pic.jpg"))
        checkEqual(moved.url.path, "/new/pic.jpg")
        checkEqual(moved.filename, "pic.jpg")
        checkEqual(moved.byteSize, 4096)            // preserved
        checkEqual(moved.creationDate, date)        // preserved
        checkNotEqual(moved, original)              // identity is the URL
    }

    test("equatableComparesAllFields") {
        // Equatable is synthesized over every stored field, so identical photos
        // collapse in a Set while a differing size keeps them distinct.
        let a = Fixtures.photo("dup.jpg", size: 1)
        let aCopy = Fixtures.photo("dup.jpg", size: 1)
        let b = Fixtures.photo("dup.jpg", size: 9999)
        checkEqual(a, aCopy)
        checkEqual(Set([a, aCopy]).count, 1)
        checkNotEqual(a, b)
        checkEqual(a.id, b.id)                       // identity (Identifiable) is the URL
    }
}
