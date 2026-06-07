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
    @State private var captionText = ""
    @State private var captionPos: ImageEditor.Caption.Position = .bottomRight
    @State private var captionColor: Color = .white
    @State private var captionHex: String = "FFFFFF"
    @State private var captionNorm: CGPoint?       // free drag placement (nil = use preset)
    @State private var logoImage: CGImage?
    @State private var logoName = ""
    @State private var logoPos: ImageEditor.Caption.Position = .bottomLeft
    @State private var logoSize: Double = 12      // % of canvas short edge
    @State private var logoOpacity: Double = 100  // %
    @State private var preview: NSImage?
    @State private var rendering = false
    @State private var busy = false
    @State private var renderToken = 0

    private var sources: [URL] { ordered.map(\.url) }
    private var gapFraction: CGFloat { CGFloat(min(max(gapPercent, 0), 20)) / 100 }

    private var caption: ImageEditor.Caption? {
        let t = captionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let cg = NSColor(captionColor).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1)
        return ImageEditor.Caption(text: t, position: captionPos, color: cg,
                                   sizeFraction: 0.045, normPosition: captionNorm)
    }
    private var logo: ImageEditor.Logo? {
        guard let logoImage else { return nil }
        return ImageEditor.Logo(image: logoImage, position: logoPos,
                                sizeFraction: CGFloat(logoSize) / 100, opacity: CGFloat(logoOpacity) / 100)
    }

    /// Aspect-fit `imageSize` inside `container` (minus `inset` padding), centered
    /// — mirrors `.scaledToFit().padding()` so the drag overlay lines up.
    static func fitRect(_ imageSize: NSSize, in container: CGSize, inset: CGFloat) -> CGRect {
        let avail = CGSize(width: max(1, container.width - inset * 2), height: max(1, container.height - inset * 2))
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: avail) }
        let s = min(avail.width / imageSize.width, avail.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private let captionSwatches: [Color] = [.white, .black, .red, .yellow, .green, .blue]

    private func setCaptionColor(_ c: Color) { captionColor = c; captionHex = hexString(c) }

    private func hexString(_ c: Color) -> String {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
    private func color(fromHex raw: String) -> Color? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
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
                                    captionNorm = CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
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
                HStack(spacing: 10) {
                    Image(systemName: "textformat").foregroundStyle(.secondary)
                    TextField("캡션/워터마크 (선택)", text: $captionText)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Picker("", selection: $captionPos) {
                        ForEach(ImageEditor.Caption.Position.allCases) { Text(positionLabel($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 84).disabled(captionText.isEmpty)
                    .onChange(of: captionPos) { _, _ in captionNorm = nil }   // preset clears free drag
                    if captionNorm != nil {
                        Image(systemName: "hand.draw.fill").foregroundStyle(.secondary)
                            .help("미리보기에서 끌어 위치를 정함")
                    }

                    Text("색").foregroundStyle(.secondary).disabled(captionText.isEmpty)
                    ColorPicker("", selection: $captionColor, supportsOpacity: false)
                        .labelsHidden().disabled(captionText.isEmpty)
                    ForEach(captionSwatches, id: \.self) { c in
                        Button { setCaptionColor(c) } label: {
                            Circle().fill(c).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.white.opacity(0.4)))
                        }.buttonStyle(.plain).disabled(captionText.isEmpty)
                    }
                    Text("#").foregroundStyle(.secondary)
                    TextField("HEX", text: $captionHex)
                        .frame(width: 70).textFieldStyle(.roundedBorder).disabled(captionText.isEmpty)
                        .onChange(of: captionHex) { _, v in if let c = color(fromHex: v) { captionColor = c } }
                    Spacer()
                }
                .onChange(of: captionColor) { _, c in
                    let h = hexString(c); if h != captionHex { captionHex = h }
                }
                HStack(spacing: 10) {
                    Image(systemName: "photo.badge.plus").foregroundStyle(.secondary)
                    if logoImage == nil {
                        Button("이미지 워터마크…") { pickLogo() }
                    } else {
                        Text(logoName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading)
                        Button { logoImage = nil; logoName = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        Picker("", selection: $logoPos) {
                            ForEach(ImageEditor.Caption.Position.allCases) { Text(positionLabel($0)).tag($0) }
                        }.labelsHidden().frame(width: 90)
                        Text("크기").foregroundStyle(.secondary)
                        Slider(value: $logoSize, in: 3...40).frame(width: 80)
                        Text("투명").foregroundStyle(.secondary)
                        Slider(value: $logoOpacity, in: 10...100).frame(width: 80)
                    }
                    Spacer()
                }
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
                    AsyncThumbnail(url: photo.url)
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
        let cap = "\(captionText)|\(captionPos.rawValue)|\(captionHex)|\(captionNorm?.x ?? -1),\(captionNorm?.y ?? -1)"
        let lg = "\(logoName)|\(logoPos.rawValue)|\(logoSize)|\(logoOpacity)"
        return "\(layout.rawValue)|\(gapPercent)|\(background.rawValue)|\(gridRows ?? 0)|\(cap)|\(lg)|\(ordered.map(\.url.path).joined(separator: ">"))"
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

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.prompt = "워터마크로 사용"
        guard panel.runModal() == .OK, let url = panel.url,
              let cg = ImageEditor.orientedCGImage(url) else { return }
        logoImage = cg
        logoName = url.lastPathComponent
    }

    private func save() {
        busy = true
        let srcs = sources, lay = layout, gap = gapFraction, bg = background.cgColor, gr = gridRows, cap = caption, lg = logo
        let dir = ordered[0].url.deletingLastPathComponent()
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
            else { model.showToast("합치기에 실패했습니다.") }
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

private func positionLabel(_ p: ImageEditor.Caption.Position) -> String {
    switch p {
    case .bottomLeft: return "좌하"
    case .bottomCenter: return "하단"
    case .bottomRight: return "우하"
    case .topLeft: return "좌상"
    case .topCenter: return "상단"
    case .topRight: return "우상"
    case .center: return "중앙"
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
