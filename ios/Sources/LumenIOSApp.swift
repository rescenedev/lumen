import SwiftUI

/// iOS entry point. Lumen for iOS is a **photo manager** for people who find
/// organizing photos painful — browse the library, then a Tinder-style organize
/// mode to keep/trash by swiping. (Editing/combine come later.)
@main
struct LumenIOSApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
    }
}
