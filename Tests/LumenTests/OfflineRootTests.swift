import Foundation
@testable import LumenKit

/// The reconcile prune decision: a *missing* root on a network/NAS volume is
/// "temporarily offline" (preserve its photos); a missing *local* folder was
/// renamed/moved/deleted (prune, so stale sidebar folders don't linger).
func offlineRootTests() {
    test("missingLocalPathIsNotNetwork") {
        // A nonexistent local path can't be stat'd → falls back to path shape →
        // not under /Volumes → treated as renamed/moved (prune).
        let gone = URL(fileURLWithPath: "/Users/nobody/Desktop/untitled folder 3")
        check(!AppModel.isOfflineNetworkRoot(gone))
    }

    test("missingVolumesPathIsNetwork") {
        // An unmounted NAS lives under /Volumes and can't be stat'd → preserve.
        let nas = URL(fileURLWithPath: "/Volumes/PhotoNAS/Library")
        check(AppModel.isOfflineNetworkRoot(nas))
    }

    test("existingLocalDirIsNotNetwork") {
        // A real local directory reports volumeIsLocal == true → not preserved.
        check(!AppModel.isOfflineNetworkRoot(URL(fileURLWithPath: "/tmp")))
    }
}
