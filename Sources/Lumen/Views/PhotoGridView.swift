import SwiftUI

/// Scrollable grid of thumbnails with Finder-style multi-selection
/// (click, ⌘-click toggle, ⇧-click range), double-click-to-open,
/// spacebar Quick Look, and arrow-key navigation.
struct PhotoGridView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var gridFocused: Bool

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.thumbnailSize, maximum: model.thumbnailSize * 1.4),
                  spacing: columnSpacing)]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.groupByMonth {
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.monthGroups, id: \.title) { group in
                            Section {
                                LazyVGrid(columns: columns, spacing: 20) {
                                    ForEach(group.photos) { photo in cell(photo) }
                                }
                            } header: {
                                Text(group.title)
                                    .font(.title3.bold())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(.bar)
                            }
                        }
                    }
                    .padding(20)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(model.visiblePhotos) { photo in cell(photo) }
                    }
                    .padding(20)
                    .background(
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { model.clearSelection() }
                    )
                }
            }
            .onChange(of: model.selectionAnchor) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { measuredWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in measuredWidth = w }
                }
            )
        }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onAppear { gridFocused = true }
        .onKeyPress(keys: [.leftArrow]) { move(-1, $0) }
        .onKeyPress(keys: [.rightArrow]) { move(1, $0) }
        .onKeyPress(keys: [.upArrow]) { move(-columnCount, $0) }
        .onKeyPress(keys: [.downArrow]) { move(columnCount, $0) }
        .browserKeyHandlers()
    }

    /// Number of columns currently shown, for up/down navigation. Mirrors the
    /// adaptive LazyVGrid layout: as many columns of at least `thumbnailSize`
    /// (with `columnSpacing` gaps) as fit in the padded content width.
    @State private var measuredWidth: CGFloat = 0
    private let gridPadding: CGFloat = 20
    private let columnSpacing: CGFloat = 18
    private var columnCount: Int {
        let available = (measuredWidth > 0 ? measuredWidth : 800) - gridPadding * 2
        let minCell = model.thumbnailSize
        return max(1, Int((available + columnSpacing) / (minCell + columnSpacing)))
    }

    private func cell(_ photo: Photo) -> some View {
        ThumbnailCell(
            photo: photo,
            isSelected: model.selection.contains(photo.id),
            isFavorite: model.isFavorite(photo),
            rating: model.rating(photo),
            label: model.label(photo),
            size: model.thumbnailSize
        )
        .equatable()
        .id(photo.id)
        .onTapGesture(count: 2) { model.openViewer(photo) }
        .onTapGesture(count: 1) {
            SelectionInput.click(photo, in: model.visiblePhotos, model: model)
            gridFocused = true
        }
        .contextMenu { PhotoContextMenu(photo: photo) }
    }

    // MARK: - Keyboard

    private func move(_ delta: Int, _ press: KeyPress) -> KeyPress.Result {
        let photos = model.visiblePhotos
        guard !photos.isEmpty else { return .ignored }
        let current = model.selectionAnchor.flatMap { id in photos.firstIndex { $0.id == id } } ?? -1
        let next = max(0, min(photos.count - 1, current + delta))
        let target = photos[next]
        if press.modifiers.contains(.shift) {
            model.extendSelection(to: target, in: photos)
            model.selectionAnchor = target.id
        } else {
            model.selectOnly(target)
        }
        return .handled
    }
}

/// Shared click → selection translation used by both the grid and the list,
/// reading the live modifier flags to implement Finder-style selection.
@MainActor
enum SelectionInput {
    static func click(_ photo: Photo, in ordered: [Photo], model: AppModel) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            model.toggleSelection(photo)
        } else if flags.contains(.shift) {
            model.extendSelection(to: photo, in: ordered)
            model.selectionAnchor = photo.id
        } else {
            model.selectOnly(photo)
        }
    }
}
