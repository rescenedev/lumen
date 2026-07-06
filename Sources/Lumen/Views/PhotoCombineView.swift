import SwiftUI
import UniformTypeIdentifiers

/// Combine several photos into one new image (non-destructive). Strips join the
/// photos side-by-side / stacked; the grid makes a square collage.
struct PhotoCombineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let photos: [Photo]

    init(photos: [Photo]) {
        self.photos = photos
        _ordered = State(initialValue: photos)
    }

    @State private var ordered: [Photo]            // drag-reorderable source order
    @State private var dragging: Photo?
    @State private var layout: ImageEditor.CombineLayout = .horizontal
    @State private var gapPercent: Double = 1.5
    @State private var background: BackgroundChoice = .white
    @State private var resolution: CombineSize = .px2048
    @State private var gridRowsText: String = ""
    @State private var watermark = WatermarkSettings()
    @State private var preview: NSImage?
    @State private var rendering = false
    @State private var busy = false
    @State private var renderToken = 0

    private var sources: [URL] { ordered.map(\.url) }
    private var gapFraction: CGFloat { CGFloat(min(max(gapPercent, 0), 20)) / 100 }

    private var caption: ImageEditor.Caption? { watermark.caption }
    private var logo: ImageEditor.Logo? { watermark.logo }

    /// Aspect-fit `imageSize` inside `container` (minus `inset` padding), centered
    /// — mirrors `.scaledToFit().padding()` so the drag overlay lines up.
    static func fitRect(_ imageSize: NSSize, in container: CGSize, inset: CGFloat) -> CGRect {
        let avail = CGSize(width: max(1, container.width - inset * 2), height: max(1, container.height - inset * 2))
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: avail) }
        let s = min(avail.width / imageSize.width, avail.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// User types the number of rows. Empty or invalid → auto (nil = square-ish).
    /// Clamped to 1…count, and only applies to the grid layout.
    private var gridRows: Int? {
        guard layout == .grid,
              let r = Int(gridRowsText.trimmingCharacters(in: .whitespaces)), r >= 1 else { return nil }
        return min(r, photos.count)
    }
    /// The grid shape actually produced — shown back to the user. `rows × widest
    /// row`, matching the row-driven layout (partial rows centered at the bottom).
    private var gridShape: (rows: Int, cols: Int) {
        let n = photos.count
        let rows = max(1, min(gridRows ?? Int(Double(n).squareRoot().rounded()), n))
        return (rows, Int((Double(n) / Double(rows)).rounded(.up)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Combine \(photos.count) Photos").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            ZStack {
                Color.black.opacity(0.25)
                if let preview {
                    GeometryReader { geo in
                        let rect = Self.fitRect(preview.size, in: geo.size, inset: 16)
                        Image(nsImage: preview).resizable().scaledToFit().padding(16)
                        // Drag anywhere on the image to place the caption freely.
                        if caption != nil {
                            Color.clear.contentShape(Rectangle()).frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                                    let nx = (v.location.x - rect.minX) / max(1, rect.width)
                                    let ny = (v.location.y - rect.minY) / max(1, rect.height)
                                    watermark.captionNorm = CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
                                })
                        }
                    }
                } else {
                    ProgressView()
                }
                if rendering {
                    ProgressView().controlSize(.small)
                        .padding(8).background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(20)
                }
            }
            .frame(minHeight: 360)
            Divider()

            reorderStrip
            Divider()

            VStack(spacing: 14) {
                // Every control on one line: layout · background · (rows) · spacing · resolution.
                HStack(spacing: 12) {
                    Picker("", selection: $layout) {
                        ForEach(ImageEditor.CombineLayout.allCases) { Text($0.shortLabel).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Picker("", selection: $background) {
                        ForEach(BackgroundChoice.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 130)
                    if layout == .grid {
                        Text("행").foregroundStyle(.secondary)
                        TextField("자동", text: $gridRowsText)
                            .frame(width: 38).multilineTextAlignment(.center)
                            .textFieldStyle(.roundedBorder)
                        Text("\(gridShape.rows)×\(gridShape.cols)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("간격").foregroundStyle(.secondary)
                    Slider(value: $gapPercent, in: 0...10).frame(width: 70)
                    TextField("", value: $gapPercent, format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 38).multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("%").foregroundStyle(.secondary)
                    Picker("", selection: $resolution) {
                        ForEach(CombineSize.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
                WatermarkBar(settings: $watermark, freeDrag: true)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save Combined") { save() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(busy || preview == nil)
                }
            }
            .padding(16)
        }
        .frame(width: 860, height: 810)
        .onAppear { instantPreview() }
        .task(id: renderKey) { await renderPreview() }
    }

    /// Horizontal strip of source thumbnails; drag to reorder how they're joined.
    private var reorderStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, photo in
                    AsyncThumbnail(url: photo.url, mtime: photo.cacheMtime,
                                   maxPixel: ThumbnailCache.tier(forPointSize: 52))
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            Text("\(index + 1)").font(.caption2.bold().monospacedDigit())
                                .padding(2).frame(minWidth: 16)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white).padding(2)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
                        .opacity(dragging == photo ? 0.35 : 1)
                        .onDrag { dragging = photo; return NSItemProvider(object: photo.url.absoluteString as NSString) }
                        .onDrop(of: [.text], delegate: CombineReorderDrop(item: photo, ordered: $ordered, dragging: $dragging))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(height: 72)
    }

    private var renderKey: String {
        "\(layout.rawValue)|\(gapPercent)|\(background.rawValue)|\(gridRows ?? 0)|\(watermark.renderKey)|\(ordered.map(\.url.path).joined(separator: ">"))"
    }

    /// Composite the grid thumbnails already in memory (512px) — instant, no disk
    /// decode — so opening the sheet never stutters. The async pass below refines.
    private func instantPreview() {
        let imgs = sources.compactMap { url -> CGImage? in
            ThumbnailCache.shared.cached(for: url, maxPixel: ThumbnailCache.gridMaxPixel)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard imgs.count == sources.count,
              let cg = ImageEditor.composite(imgs, layout: layout, gapFraction: gapFraction,
                                             background: background.cgColor, gridRows: gridRows,
                                             caption: caption, logo: logo)
        else { return }
        preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func renderPreview() async {
        renderToken += 1
        let token = renderToken
        rendering = true
        let srcs = sources, lay = layout, gap = gapFraction, bg = background.cgColor, gr = gridRows, cap = caption, lg = logo
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            // Downsample sources for a fast preview (no full-res decode).
            guard let cg = ImageEditor.renderCombined(sources: srcs, layout: lay, gapFraction: gap,
                                                      background: bg, sourceMaxPixel: 900, longEdge: 1400,
                                                      gridRows: gr, caption: cap, logo: lg)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        guard token == renderToken else { return }
        preview = img
        rendering = false
    }


    private func save() {
        guard let first = ordered.first else { return }
        busy = true
        let srcs = sources, lay = layout, gap = gapFraction, bg = background.cgColor, gr = gridRows, cap = caption, lg = logo
        let dir = first.url.deletingLastPathComponent()
        let ext = background == .transparent ? "png" : "jpg"
        let dest = ImageEditor.uniqueFileURL(in: dir, base: "Combined", ext: ext)
        let maxPixel = resolution.pixels
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                ImageEditor.combine(sources: srcs, layout: lay, gapFraction: gap,
                                    background: bg, sourceMaxPixel: maxPixel, to: dest, gridRows: gr,
                                    caption: cap, logo: lg)
            }.value
            busy = false
            if ok { model.didCombine(output: dest); dismiss() }
            else { model.showToast(String(localized: "Couldn’t merge the photos.", bundle: .lumen)) }
        }
    }
}

/// Per-photo resolution for the combined output (downsamples each source so a
/// many-photo strip doesn't make a huge canvas).
enum CombineSize: String, CaseIterable, Identifiable {
    case px1024, px2048, px3000, original
    var id: String { rawValue }
    var label: String {
        switch self {
        case .px1024: return "사진당 1024px"
        case .px2048: return "사진당 2048px"
        case .px3000: return "사진당 3000px"
        case .original: return "원본 해상도(느림)"
        }
    }
    var pixels: Int? {
        switch self {
        case .px1024: return 1024
        case .px2048: return 2048
        case .px3000: return 3000
        case .original: return nil
        }
    }
}

/// Reorders the source list as a dragged thumbnail passes over another.
private struct CombineReorderDrop: DropDelegate {
    let item: Photo
    @Binding var ordered: [Photo]
    @Binding var dragging: Photo?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = ordered.firstIndex(of: dragging),
              let to = ordered.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

enum BackgroundChoice: String, CaseIterable, Identifiable {
    case white, black, transparent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .white: return "배경: 흰색"
        case .black: return "배경: 검정"
        case .transparent: return "배경: 투명(PNG)"
        }
    }
    var cgColor: CGColor {
        switch self {
        case .white: return CGColor(gray: 1, alpha: 1)
        case .black: return CGColor(gray: 0, alpha: 1)
        case .transparent: return CGColor(gray: 0, alpha: 0)
        }
    }
}
