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
    @State private var lib = PhotoLibrary()
    @State private var selectedTab: LumenTab = .home
    @State private var showSplash = true

    var body: some View {
        ZStack {
            // All five tabs stay alive in a ZStack (opacity-toggled) instead of being
            // rebuilt per switch: the collection views, their cells, and the decoded
            // thumbnails persist, so entering 전체 사진 (or any tab) does ZERO work —
            // no re-fetch, no re-layout, no thumbnail re-requests. Hidden panes also
            // pre-build at launch, so even the FIRST entry is instant.
            ZStack {
                pane(.home)      { LibraryView(library: lib) }
                pane(.allPhotos) { allPhotosTab }
                pane(.organize)  { OrganizePickerView(library: lib) }
                pane(.favorites) { favoritesTab }
                pane(.vault)     { vaultTab }
            }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: lib.authorized ? 72 : 0)
                }
            if lib.authorized {
                VStack(spacing: 0) {
                    Spacer()
                    FloatingTabBar(selected: $selectedTab)
                }
                .ignoresSafeArea(edges: .bottom)
            }
            if showSplash { SplashView().transition(.opacity) }
        }
        .task {
            async let minWait: Void = Task.sleep(for: .milliseconds(600))
            if !lib.loaded { await lib.load() }
            try? await minWait
            withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
        }
    }

    /// One persistent tab pane: hidden panes keep their state/cells but are
    /// untouchable. The 100ms fade matches the old tab-switch feel exactly.
    private func pane<Content: View>(_ tab: LumenTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .animation(.easeOut(duration: 0.10), value: selectedTab)
    }

    @ViewBuilder private var allPhotosTab: some View {
        if let scope = lib.scopes.first(where: { $0.id == "all" }) {
            AlbumGalleryView(scope: scope, library: lib, onClose: nil)
        } else {
            emptyTab("photo.stack", lib.loaded ? "사진이 없어요" : nil)
        }
    }

    @ViewBuilder private var favoritesTab: some View {
        if let scope = lib.scopes.first(where: { $0.title == "즐겨찾기" }) {
            AlbumGalleryView(scope: scope, library: lib, onClose: nil)
        } else {
            emptyTab("star", lib.loaded ? "즐겨찾기한 사진이 없어요" : nil,
                     sub: "위로 올리면 즐겨찾기에 추가돼요")
        }
    }

    @ViewBuilder private var vaultTab: some View {
        if let scope = lib.scopes.first(where: { $0.collection?.localizedTitle == "Lumen" }) {
            AlbumGalleryView(scope: scope, library: lib, onClose: nil)
        } else {
            emptyTab("tray", lib.loaded ? "보관한 사진이 없어요" : nil,
                     sub: "♥로 보관한 사진이 여기 모여요")
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
        .background(Capsule().fill(Color(white: 0.11).opacity(0.9)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.07)))
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
    }

    private func tabBtn(_ tab: LumenTab, _ icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.75)) { selected = tab }
        } label: {
            ZStack {
                if selected == tab {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.26))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                }
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected == tab ? .white : Color(white: 0.55))
                    .scaleEffect(selected == tab ? 1.05 : 1)
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
