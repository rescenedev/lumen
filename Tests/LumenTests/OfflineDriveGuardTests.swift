import Foundation
@testable import LumenKit

/// Disconnected-drive guard: NAS/USB volumes can vanish at any moment. Roots
/// whose volume is currently unmounted are surfaced as `offlineRoots` so the
/// sidebar can gray them out and block selection; when the volume mounts
/// again they leave the set and the library rescans automatically.
func offlineDriveGuardTests() {

    let nas = URL(fileURLWithPath: "/Volumes/nas", isDirectory: true)
    let usb = URL(fileURLWithPath: "/Volumes/orico/photos", isDirectory: true)
    let home = URL(fileURLWithPath: "/Users/me/Pictures", isDirectory: true)

    // MARK: computeOfflineRoots

    test("computeOfflineRoots: missing /Volumes roots are offline (network AND usb)") {
        let offline = AppModel.computeOfflineRoots([nas, usb, home]) { _ in false }
        checkEqual(offline, Set([nas, usb]),
                   "a missing home-folder root was deleted, not disconnected — it must NOT be offline")
    }

    test("computeOfflineRoots: reachable roots are never offline") {
        let offline = AppModel.computeOfflineRoots([nas, usb, home]) { _ in true }
        check(offline.isEmpty)
    }

    test("computeOfflineRoots: mount transition removes the root from the set") {
        var mounted = false
        func exists(_ url: URL) -> Bool { mounted }
        checkEqual(AppModel.computeOfflineRoots([nas], exists: exists), Set([nas]))
        mounted = true
        check(AppModel.computeOfflineRoots([nas], exists: exists).isEmpty,
              "after the volume mounts the root must leave the offline set")
    }

    test("computeOfflineRoots: empty roots") {
        check(AppModel.computeOfflineRoots([]) { _ in false }.isEmpty)
    }

    // MARK: path-under-root membership (drives the gray-out per folder row)

    test("isUnderAny: root itself and its descendants match") {
        let offline: Set<URL> = [nas]
        check(AppModel.url(nas, isUnderAny: offline), "the root itself is offline")
        check(AppModel.url(nas.appendingPathComponent("2026/eu"), isUnderAny: offline),
              "descendants of an offline root are offline")
    }

    test("isUnderAny: sibling with shared prefix does NOT match") {
        let offline: Set<URL> = [nas]
        let sibling = URL(fileURLWithPath: "/Volumes/nas2/photos", isDirectory: true)
        check(!AppModel.url(sibling, isUnderAny: offline),
              "/Volumes/nas2 must not be treated as under /Volumes/nas (path-component boundary)")
    }

    test("isUnderAny: unrelated path and empty set") {
        check(!AppModel.url(home, isUnderAny: [nas]))
        check(!AppModel.url(nas, isUnderAny: []))
    }
}
