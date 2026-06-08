import SwiftUI

/// iOS entry point. WIP scaffold (branch `feat/ios`) — proves the cross-platform
/// `ImageEditor` engine runs on iOS. See ../IOS_PORT.md for the full plan.
@main
struct LumenIOSApp: App {
    var body: some Scene {
        WindowGroup {
            CombineDemoView()
        }
    }
}
