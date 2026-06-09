import Foundation
@testable import LumenKit

func thumbnailCacheTests() {
    test("tierSmallCellsUse256") {
        checkEqual(ThumbnailCache.tier(forPointSize: 90), 256)    // slider minimum
        checkEqual(ThumbnailCache.tier(forPointSize: 128), 256)   // boundary
    }

    test("tierLargeCellsUseFullResolution") {
        checkEqual(ThumbnailCache.tier(forPointSize: 129), ThumbnailCache.gridMaxPixel)
        checkEqual(ThumbnailCache.tier(forPointSize: 320), ThumbnailCache.gridMaxPixel)  // slider max
    }

    test("cacheMtimeMatchesScanDate") {
        let date = Fixtures.date("2024-03-01T08:00:00Z")
        let photo = Photo(url: URL(fileURLWithPath: "/x/a.jpg"),
                          byteSize: 1, creationDate: nil, modificationDate: date)
        checkEqual(photo.cacheMtime, date.timeIntervalSince1970)
    }

    test("cacheMtimeFallsBackToZeroLikeTheCacheKey") {
        // The 0 fallback must match ThumbnailCache's own stat-failure fallback
        // so disk-cache keys stay consistent for files with no mtime.
        let photo = Photo(url: URL(fileURLWithPath: "/x/a.jpg"),
                          byteSize: 1, creationDate: nil, modificationDate: nil)
        checkEqual(photo.cacheMtime, 0)
    }
}
