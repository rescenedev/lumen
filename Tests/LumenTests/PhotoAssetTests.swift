import Foundation
@testable import LumenKit

/// The synthetic `photos-library://` URL is the linchpin of the Photos source:
/// every PHAsset is wrapped in one so the URL-keyed machinery (selection, grid,
/// viewer, metadata, cache) works unchanged. If the localIdentifier doesn't
/// round-trip exactly, image loads silently fail — so this is the highest-risk
/// surface to test.
func photoAssetTests() {
    test("localIdentifierRoundTripsWithSlashes") {
        // PHAsset localIdentifiers look like "<UUID>/L0/001" — the slashes must
        // survive being embedded in a URL.
        let id = "9F2A1B3C-1234-5678-ABCD-0123456789AB/L0/001"
        let photo = Photo.asset(localIdentifier: id, creationDate: nil, modificationDate: nil)
        check(photo.isAsset)
        check(photo.assetLocalIdentifier == id, "got \(photo.assetLocalIdentifier ?? "nil")")
    }

    test("localIdentifierRoundTripsSimple") {
        let id = "ABCDEF01-2345"
        let photo = Photo.asset(localIdentifier: id, creationDate: nil, modificationDate: nil)
        check(photo.assetLocalIdentifier == id)
    }

    test("urlHelperMatches") {
        let id = "X1/L0/099"
        let photo = Photo.asset(localIdentifier: id, creationDate: nil, modificationDate: nil)
        check(photo.url.photosAssetLocalIdentifier == id)
    }

    test("captionIsReadableNotEncoded") {
        // filename (grid caption) is the date label — never the raw/encoded id.
        let photo = Photo.asset(localIdentifier: "AAA/L0/1",
                                creationDate: Fixtures.date("2025-09-20T17:30:00Z"),
                                modificationDate: nil)
        let name = photo.filename
        check(!name.contains("/"), "caption must not contain a slash: \(name)")
        check(!name.contains("%"), "caption must not be percent-encoded: \(name)")
        check(!name.contains(" "), "caption must not contain a space: \(name)")
        check(!name.isEmpty)
    }

    test("undatedAssetGetsFallbackCaption") {
        let photo = Photo.asset(localIdentifier: "AAA", creationDate: nil, modificationDate: nil)
        check(photo.filename == "Photo", "got \(photo.filename)")
    }

    test("filephotoIsNotAsset") {
        let file = Photo(url: URL(fileURLWithPath: "/a/b.jpg"),
                         byteSize: 1, creationDate: nil, modificationDate: nil)
        check(!file.isAsset)
        check(file.assetLocalIdentifier == nil)
        check(URL(fileURLWithPath: "/a/b.jpg").photosAssetLocalIdentifier == nil)
    }
}
