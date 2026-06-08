import SwiftUI

/// Lumen for iOS — a native photo *manager* for people who find organizing
/// photos painful: browse the library, then keep/favorite/trash with light
/// gestures. (Editing/combine come later.)
@main
struct LumenIOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.lumenAccent)
        }
    }
}

/// Hosts the app and shows a brief "Lumen" splash on launch, fading into the
/// library once it's had a moment to load.
struct RootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            LibraryView()
            if showSplash {
                SplashView().transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
        }
    }
}

/// Dead-simple splash: the word "Lumen" on the app's slate.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            Text("Lumen")
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
    }
}
