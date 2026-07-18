import Foundation
@testable import LumenKit

/// The scope pass (Favorites/On This Day/Label/Tag/Album/Duplicates membership
/// filtering) used to run inside `scoped()` on the MAIN thread before the
/// async-sort decision — measured 94ms entering Favorites on the 66.8k
/// library (perf probe, v0.5.3). It is now a pure static function over value
/// snapshots so large libraries can run it off-main with the sort.
func scopePassTests() {

    func photo(_ path: String, created: Date? = nil) -> Photo {
        Photo(url: URL(fileURLWithPath: path), byteSize: 1, creationDate: created, modificationDate: nil)
    }

    let a = photo("/lib/a.jpg"), b = photo("/lib/b.jpg"), c = photo("/lib/c.jpg")

    func meta(favorite: Bool = false, label: ColorLabel = .none, tags: [String] = []) -> PhotoMeta {
        var m = PhotoMeta()
        m.favorite = favorite; m.label = label; m.tags = tags
        return m
    }

    test("scopePass: allPhotos passes through untouched") {
        let out = AppModel.scopePass([a, b], scope: .allPhotos, metaByPath: [:],
                                     duplicatePaths: [], albumPaths: nil, byFolder: [:])
        checkEqual(out.map(\.url), [a, b].map(\.url))
    }

    test("scopePass: favorites keeps only photos whose meta says favorite") {
        let metaMap = ["/lib/a.jpg": meta(favorite: true), "/lib/b.jpg": meta()]
        let out = AppModel.scopePass([a, b, c], scope: .favorites, metaByPath: metaMap,
                                     duplicatePaths: [], albumPaths: nil, byFolder: [:])
        checkEqual(out.map(\.url.path), ["/lib/a.jpg"])
    }

    test("scopePass: onThisDay matches month+day across years, fixed clock") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
        let sameDay2019 = cal.date(from: DateComponents(year: 2019, month: 7, day: 18, hour: 9))!
        let otherDay = cal.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 9))!
        let p1 = photo("/lib/match.jpg", created: sameDay2019)
        let p2 = photo("/lib/no.jpg", created: otherDay)
        let p3 = photo("/lib/nodate.jpg")
        let out = AppModel.scopePass([p1, p2, p3], scope: .onThisDay, metaByPath: [:],
                                     duplicatePaths: [], albumPaths: nil, byFolder: [:],
                                     now: now, calendar: cal)
        checkEqual(out.map(\.url.path), ["/lib/match.jpg"])
    }

    test("scopePass: recentlyAdded uses the 30-day cutoff") {
        let now = Date()
        let fresh = photo("/lib/fresh.jpg", created: now.addingTimeInterval(-5 * 86_400))
        let stale = photo("/lib/stale.jpg", created: now.addingTimeInterval(-40 * 86_400))
        let out = AppModel.scopePass([fresh, stale], scope: .recentlyAdded, metaByPath: [:],
                                     duplicatePaths: [], albumPaths: nil, byFolder: [:], now: now)
        checkEqual(out.map(\.url.path), ["/lib/fresh.jpg"])
    }

    test("scopePass: label, tag, duplicates, album membership") {
        let metaMap = ["/lib/a.jpg": meta(label: .red, tags: ["trip"]),
                       "/lib/b.jpg": meta(label: .blue, tags: ["work", "trip"])]
        let byLabel = AppModel.scopePass([a, b, c], scope: .label(.red), metaByPath: metaMap,
                                         duplicatePaths: [], albumPaths: nil, byFolder: [:])
        checkEqual(byLabel.map(\.url.path), ["/lib/a.jpg"])

        let byTag = AppModel.scopePass([a, b, c], scope: .tag("trip"), metaByPath: metaMap,
                                       duplicatePaths: [], albumPaths: nil, byFolder: [:])
        checkEqual(byTag.map(\.url.path), ["/lib/a.jpg", "/lib/b.jpg"])

        let dupes = AppModel.scopePass([a, b], scope: .duplicates, metaByPath: [:],
                                       duplicatePaths: ["/lib/b.jpg"], albumPaths: nil, byFolder: [:])
        checkEqual(dupes.map(\.url.path), ["/lib/b.jpg"])

        let inAlbum = AppModel.scopePass([a, b, c], scope: .album(UUID()), metaByPath: [:],
                                         duplicatePaths: [], albumPaths: ["/lib/c.jpg"], byFolder: [:])
        checkEqual(inAlbum.map(\.url.path), ["/lib/c.jpg"])

        let missingAlbum = AppModel.scopePass([a, b], scope: .album(UUID()), metaByPath: [:],
                                              duplicatePaths: [], albumPaths: nil, byFolder: [:])
        check(missingAlbum.isEmpty, "a deleted album resolves to an empty scope, not a crash")
    }

    test("scopePass: folder uses the folder index with a path-component boundary") {
        let inNas = photo("/Volumes/nas/x.jpg"), inSub = photo("/Volumes/nas/sub/y.jpg")
        let sibling = photo("/Volumes/nas2/z.jpg")
        let byFolder = ["/Volumes/nas": [inNas], "/Volumes/nas/sub": [inSub], "/Volumes/nas2": [sibling]]
        let out = AppModel.scopePass([], scope: .folder(URL(fileURLWithPath: "/Volumes/nas")),
                                     metaByPath: [:], duplicatePaths: [], albumPaths: nil,
                                     byFolder: byFolder)
        checkEqual(Set(out.map(\.url.path)), Set(["/Volumes/nas/x.jpg", "/Volumes/nas/sub/y.jpg"]),
                   "/Volumes/nas2 must not leak into /Volumes/nas")
    }
}
