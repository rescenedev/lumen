import SwiftUI
import Photos

/// Photos-app-style thumbnail grid for an album. Tap a photo to open the
/// full-screen viewer (and organize from there).
struct AlbumGalleryView: View {
    let scope: OrganizeScope
    let library: PhotoLibrary
    let onClose: (() -> Void)?      // nil = shown as a tab (no close button, no back-swipe)
    let scrollTopKey: Int           // bumped by a tab re-tap → grid scrolls to top

    @AppStorage("lumen.lastOrganizedScopeId") private var lastOrganizedScopeId = "all"

    @State private var source: GridSource
    @State private var ver = 0
    @State private var open: StartAt?

    init(scope: OrganizeScope, library: PhotoLibrary, onClose: (() -> Void)?, scrollTopKey: Int = 0) {
        self.scope = scope
        self.library = library
        self.onClose = onClose
        self.scrollTopKey = scrollTopKey
        // Build the grid eagerly so it slides in as one unit with the header — but
        // the source is now lazy (resolves its fetch on first cell draw), so this
        // touches no PhotoKit and never blocks the open, even on a 60k album.
        let gs = library.gridSource(for: scope)
        gs.warm()   // resolve the fetch off-main now, so the first cell draws from cache mid-slide
        _source = State(initialValue: gs)
    }

    var body: some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            if source.count == 0 {
                Text("사진이 없어요").font(.subheadline).foregroundStyle(.white.opacity(0.5))
            } else {
                PhotoGridView(source: source, manager: library.manager, reloadKey: ver,
                              onTap: { lastOrganizedScopeId = scope.id; open = StartAt(index: $0) },
                              onBack: onClose ?? {},
                              bottomInset: onClose == nil ? 88 : 28,
                              scrollTopKey: scrollTopKey)
                    .ignoresSafeArea(edges: .bottom)
            }
            header
        }
        .preferredColorScheme(.dark)
        .task {
            // Self-test helper: jump straight into the viewer.
            if ProcessInfo.processInfo.arguments.contains("-autoViewer"), open == nil, source.count > 0 {
                open = StartAt(index: 0)
            }
        }
        // Persistent tab panes are never re-init'd, so pick up library changes
        // (deletes, new photos — scope equality covers count+cover) here instead.
        .onChange(of: scope) { _, s in
            source = library.gridSource(for: s); ver += 1
        }
        .fullScreenCover(item: $open, onDismiss: {
            // Refresh after the viewer — e.g. un-favorited photos leave the 즐겨찾기 grid
            // right away, without waiting for PhotoKit's change notification.
            source = library.freshGridSource(for: scope); ver += 1
        }) { start in
            OrganizeView(scope: scope, library: library, startIndex: start.index)
        }
    }

    private var header: some View {
        ZStack {
            Text(scope.title).font(.headline).foregroundStyle(.white)
            if let onClose {
                HStack {
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.headline.bold()).foregroundStyle(.white)
                            .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A starting index, wrapped so it can drive `.fullScreenCover(item:)`.
struct StartAt: Identifiable { let id = UUID(); let index: Int }
