import SwiftUI

enum LumenTab { case home, allPhotos, organize, favorites, vault }

@main
struct LumenIOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.lumenAccent)
        }
    }
}

struct RootView: View {
    @AppStorage("lumen.lastOrganizedScopeId") private var lastOrganizedScopeId = "all"

    @State private var lib = PhotoLibrary()
    @State private var selectedTab: LumenTab = .home
    @State private var showSplash = true
    /// Cached organize scope — only swapped when scope *identity* (id) changes,
    /// not on count/cover updates, so a library reload never collapses the
    /// fullScreenCover that OrganizeView is presenting.
    @State private var organizeScope: OrganizeScope?

    var body: some View {
        ZStack {
            tabContent
            if showSplash { SplashView().transition(.opacity) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if lib.authorized {
                FloatingTabBar(selected: $selectedTab)
            }
        }
        .task {
            // Run load + minimum splash timer concurrently.
            // Splash hides after max(load time, 600ms) so the tab bar is always
            // ready before the user sees the home screen.
            async let minWait: Void = Task.sleep(for: .milliseconds(600))
            if !lib.loaded { await lib.load() }
            try? await minWait
            withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
        }
        .onChange(of: lib.scopes) { _, scopes in
            let target = scopes.first(where: { $0.id == lastOrganizedScopeId })
                      ?? scopes.first(where: { $0.id == "all" })
            if target?.id != organizeScope?.id { organizeScope = target }
        }
        .onChange(of: lastOrganizedScopeId) { _, newId in
            if let scope = lib.scopes.first(where: { $0.id == newId }) {
                organizeScope = scope
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch selectedTab {
        case .home:
            LibraryView(library: lib)
        case .allPhotos:
            if let scope = lib.scopes.first(where: { $0.id == "all" }) {
                AlbumGalleryView(scope: scope, library: lib, onClose: nil)
            } else {
                emptyTab("photo.stack", lib.loaded ? "사진이 없어요" : nil)
            }
        case .organize:
            if let scope = organizeScope {
                AlbumGalleryView(scope: scope, library: lib, onClose: nil)
            } else {
                emptyTab("sparkles", lib.loaded ? "정리할 사진이 없어요" : nil)
            }
        case .favorites:
            if let scope = lib.scopes.first(where: { $0.title == "즐겨찾기" }) {
                AlbumGalleryView(scope: scope, library: lib, onClose: nil)
            } else {
                emptyTab("star", lib.loaded ? "즐겨찾기한 사진이 없어요" : nil,
                         sub: "위로 올리면 즐겨찾기에 추가돼요")
            }
        case .vault:
            if let scope = lib.scopes.first(where: { $0.collection?.localizedTitle == "Lumen" }) {
                AlbumGalleryView(scope: scope, library: lib, onClose: nil)
            } else {
                emptyTab("tray", lib.loaded ? "보관한 사진이 없어요" : nil,
                         sub: "♥로 보관한 사진이 여기 모여요")
            }
        }
    }

    private func emptyTab(_ icon: String, _ msg: String?, sub: String? = nil) -> some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            if let msg {
                VStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(.white.opacity(0.22))
                    Text(msg).font(.subheadline).foregroundStyle(.white.opacity(0.5))
                    if let sub {
                        Text(sub).font(.footnote).foregroundStyle(.white.opacity(0.3))
                    }
                }
            } else {
                ProgressView().tint(.white.opacity(0.4))
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct FloatingTabBar: View {
    @Binding var selected: LumenTab

    var body: some View {
        HStack(spacing: 0) {
            tabBtn(.home,       "house.fill")
            tabBtn(.allPhotos,  "photo.stack.fill")
            tabBtn(.organize,   "sparkles")
            tabBtn(.favorites,  "star.fill")
            tabBtn(.vault,      "tray.full.fill")
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .background(Capsule().fill(.ultraThinMaterial).opacity(0.55))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .padding(.horizontal, 28)
        .padding(.vertical, 4)
        .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
    }

    private func tabBtn(_ tab: LumenTab, _ icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.70)) { selected = tab }
        } label: {
            ZStack {
                if selected == tab {
                    // Capsule gives maximum roundness — basically a pill/circle feel
                    Capsule()
                        .fill(.white.opacity(0.16))
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                }
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected == tab ? .white : .white.opacity(0.38))
                    .scaleEffect(selected == tab ? 1.1 : 1)
            }
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

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
