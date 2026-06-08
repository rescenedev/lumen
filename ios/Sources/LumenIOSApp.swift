import SwiftUI

/// Lumen for iOS — a native photo *manager* for people who find organizing
/// photos painful: browse the library, then a Tinder-style organize mode to
/// keep/trash by swiping. (Editing/combine come later.)
@main
struct LumenIOSApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .tint(.lumenAccent)
        }
    }
}
