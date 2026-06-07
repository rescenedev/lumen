import Foundation
@testable import LumenKit

func sortOrderTests() {
    func names(_ photos: [Photo]) -> [String] { photos.map(\.filename) }

    test("dateNewestFirst") {
        let photos = [
            Fixtures.photo("old.jpg", date: Fixtures.date("2020-01-01T00:00:00Z")),
            Fixtures.photo("new.jpg", date: Fixtures.date("2024-01-01T00:00:00Z")),
            Fixtures.photo("mid.jpg", date: Fixtures.date("2022-01-01T00:00:00Z"))
        ]
        checkEqual(names(SortOrder.dateNewest.sorted(photos)), ["new.jpg", "mid.jpg", "old.jpg"])
    }

    test("dateOldestFirst") {
        let photos = [
            Fixtures.photo("new.jpg", date: Fixtures.date("2024-01-01T00:00:00Z")),
            Fixtures.photo("old.jpg", date: Fixtures.date("2020-01-01T00:00:00Z"))
        ]
        checkEqual(names(SortOrder.dateOldest.sorted(photos)), ["old.jpg", "new.jpg"])
    }

    test("nilDateSortsLastWhenNewest") {
        let photos = [
            Fixtures.photo("nodate.jpg", date: nil),
            Fixtures.photo("dated.jpg", date: Fixtures.date("2024-01-01T00:00:00Z"))
        ]
        // Newest-first treats missing dates as distantPast → they land last.
        checkEqual(names(SortOrder.dateNewest.sorted(photos)), ["dated.jpg", "nodate.jpg"])
    }

    test("nameNaturalOrder") {
        // localizedStandardCompare → "2" before "10" (not lexicographic).
        let photos = [
            Fixtures.photo("img10.jpg"),
            Fixtures.photo("img2.jpg"),
            Fixtures.photo("img1.jpg")
        ]
        checkEqual(names(SortOrder.nameAZ.sorted(photos)), ["img1.jpg", "img2.jpg", "img10.jpg"])
        checkEqual(names(SortOrder.nameZA.sorted(photos)), ["img10.jpg", "img2.jpg", "img1.jpg"])
    }

    test("sizeOrder") {
        let photos = [
            Fixtures.photo("small.jpg", size: 100),
            Fixtures.photo("big.jpg", size: 9000),
            Fixtures.photo("mid.jpg", size: 500)
        ]
        checkEqual(names(SortOrder.sizeLargest.sorted(photos)), ["big.jpg", "mid.jpg", "small.jpg"])
        checkEqual(names(SortOrder.sizeSmallest.sorted(photos)), ["small.jpg", "mid.jpg", "big.jpg"])
    }

    test("sortingEmptyAndSingle") {
        check(SortOrder.nameAZ.sorted([]).isEmpty)
        let one = [Fixtures.photo("a.jpg")]
        checkEqual(names(SortOrder.sizeLargest.sorted(one)), ["a.jpg"])
    }

    test("allCasesHaveSystemImage") {
        for order in SortOrder.allCases {
            check(!order.systemImage.isEmpty, "\(order) missing systemImage")
        }
    }
}
