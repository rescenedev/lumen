import SwiftUI

/// Root layout: sidebar + photo grid + metadata inspector, with the
/// full-screen viewer presented as an overlay on top.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            HStack(spacing: 0) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector && model.totalCount > 0 {
                    Divider()
                    InspectorView()
                        .frame(width: 300)
                        .transition(.move(edge: .trailing))
                }
            }
            .toolbar { toolbarContent }
        }
        .overlay {
            if model.viewerIndex != nil {
                ViewerView()
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .alert("Move to Trash?", isPresented: $model.showDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.photosPendingDeletion = [] }
        } message: {
            Text(model.deletionMessage)
        }
        .sheet(isPresented: $model.showNewAlbumSheet) {
            AlbumNameSheet(title: "New Album", confirmLabel: "Create",
                           text: $model.newAlbumNameDraft) {
                model.confirmNewAlbum()
            }
        }
        .sheet(isPresented: $model.showRenameSheet) {
            RenameSheet()
        }
        .sheet(isPresented: $model.showFolderRenameSheet) {
            AlbumNameSheet(title: "Rename Folder", confirmLabel: "Rename",
                           placeholder: "Folder name", text: $model.folderRenameDraft) {
                model.confirmRenameFolder()
            }
        }
        .sheet(isPresented: $model.showAbout) { AboutView() }
        .sheet(isPresented: $model.showShortcuts) { ShortcutsView() }
        .sheet(isPresented: $model.showEditor) {
            if let target = model.editTarget { CropResizeView(photo: target) }
        }
        .sheet(isPresented: $model.showCombine) {
            PhotoCombineView(photos: model.combineTargets)
        }
        .sheet(isPresented: $model.showBatchResize) {
            BatchResizeView(photos: model.batchTargets)
        }
        .overlay(alignment: .bottom) { toastBanner }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.toast)
    }

    @ViewBuilder
    private var toastBanner: some View {
        if let toast = model.toast {
            Label(toast, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(radius: 8, y: 2)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { model.dismissToast() }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if model.committedSidebar.isPhotosLibrarySource {
            photosLibraryContent
        } else if model.totalCount == 0 {
            if model.isLoadingLibrary {
                ProgressView("Loading your photos…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView()
            }
        } else {
            PhotoBrowserView()
        }
    }

    @ViewBuilder
    private var photosLibraryContent: some View {
        switch model.photosAccess {
        case .loading where model.assetPhotos.isEmpty:
            ProgressView("Loading Photos library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            ContentUnavailableView {
                Label("Photos Access Needed", systemImage: "lock")
            } description: {
                Text("Enable Photos access in System Settings › Privacy & Security › Photos to browse your library here.")
            } actions: {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        default:
            PhotoBrowserView()
        }
    }

    private var viewModeBinding: Binding<ViewMode> {
        Binding(get: { model.viewMode }, set: { model.viewMode = $0 })
    }
    private var sortOrderBinding: Binding<SortOrder> {
        Binding(get: { model.sortOrder }, set: { model.sortOrder = $0 })
    }
    private var groupBinding: Binding<Bool> {
        Binding(get: { model.groupByMonth }, set: { model.groupByMonth = $0 })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a folder or photos to the library")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.isScanning {
                ProgressView().controlSize(.small)
            }

            Picker("View", selection: viewModeBinding) {
                ForEach(ViewMode.allCases) { mode in
                    Image(systemName: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Switch between grid and list")

            Menu {
                Picker("Sort By", selection: sortOrderBinding) {
                    ForEach(SortOrder.allCases) { order in
                        Label(order.rawValue, systemImage: order.systemImage).tag(order)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Group by Month", isOn: groupBinding)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sorting and grouping")

            FilterMenu()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
            } label: {
                Label("Info", systemImage: "sidebar.right")
            }
            .help("Toggle the info panel")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.importURLs(urls)
        }
        return true
    }
}
