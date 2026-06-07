import Foundation
@testable import LumenKit

func filterStateTests() {
    test("noneIsInactive") {
        check(!FilterState.none.isActive)
        check(FilterState.none.chips.isEmpty)
    }

    test("eachFieldActivates") {
        check(FilterState(fileType: "jpg").isActive)
        check(FilterState(minRating: 3).isActive)
        check(FilterState(label: .red).isActive)
        check(FilterState(favoritesOnly: true).isActive)
        check(FilterState(gpsOnly: true).isActive)
        check(FilterState(camera: "SONY").isActive)
    }

    test("zeroRatingIsInactive") {
        check(!FilterState(minRating: 0).isActive)
    }

    test("chipsReflectActiveFilters") {
        let state = FilterState(fileType: "heic", minRating: 4, label: .blue,
                                favoritesOnly: true, gpsOnly: true, camera: "SONY ILCE-7CM2")
        let chips = state.chips
        check(chips.contains("HEIC"), "uppercased extension")
        check(chips.contains("★ 4+"))
        check(chips.contains("Blue"))
        check(chips.contains("Favorites"))
        check(chips.contains("Has Location"))
        check(chips.contains("SONY ILCE-7CM2"))
    }

    test("noneLabelProducesNoChip") {
        // ColorLabel.none has a nil color, so it must not add a chip.
        check(!FilterState(label: ColorLabel.none).chips.contains("None"))
    }

    test("equatable") {
        checkEqual(FilterState(fileType: "jpg"), FilterState(fileType: "jpg"))
        checkNotEqual(FilterState(fileType: "jpg"), FilterState(fileType: "png"))
    }
}
