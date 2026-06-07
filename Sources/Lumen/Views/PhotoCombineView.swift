import SwiftUI

/// Combine several photos into one new image (non-destructive). Strips join the
/// photos side-by-side / stacked; the grid makes a square collage.
struct PhotoCombineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let photos: [Photo]

    @State private var layout: ImageEditor.CombineLayout = .horizontal
    @State private var gapPercent: Double = 1.5
    @State private var background: BackgroundChoice = .white
    @State private var resolution: CombineSize = .px2048
    @State private var gridRowsText: String = ""
    @State private var preview: NSImage?
    @State private var rendering = false
    @State private var busy = false
    @State private var renderToken = 0

    private var sources: [URL] { photos.map(\.url) }
    private var gapFraction: CGFloat { CGFloat(gapPercent) / 100 }

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
                    Image(nsImage: preview).resizable().scaledToFit().padding(16)
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

            VStack(spacing: 14) {
                HStack(spacing: 20) {
                    Picker("Layout", selection: $layout) {
                        ForEach(ImageEditor.CombineLayout.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu).frame(width: 220)
                    if layout == .grid {
                        HStack(spacing: 6) {
                            Text("행").foregroundStyle(.secondary)
                            TextField("자동", text: $gridRowsText)
                                .frame(width: 46).multilineTextAlignment(.center)
                                .textFieldStyle(.roundedBorder)
                            Text("\(gridShape.rows)×\(gridShape.cols)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Background", selection: $background) {
                        ForEach(BackgroundChoice.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu).frame(width: 170)
                    Spacer()
                }
                HStack {
                    Text("Spacing").foregroundStyle(.secondary)
                    Slider(value: $gapPercent, in: 0...10)
                    Text(String(format: "%.1f%%", gapPercent)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    Picker("", selection: $resolution) {
                        ForEach(CombineSize.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 150)
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
        .frame(width: 760, height: 660)
        .onAppear { instantPreview() }
        .task(id: renderKey) { await renderPreview() }
    }

    private var renderKey: String { "\(layout.rawValue)|\(gapPercent)|\(background.rawValue)|\(gridRows ?? 0)" }

    /// Composite the grid thumbnails already in memory (512px) — instant, no disk
    /// decode — so opening the sheet never stutters. The async pass below refines.
    private func instantPreview() {
        let imgs = sources.compactMap { url -> CGImage? in
            ThumbnailCache.shared.cached(for: url, maxPixel: ThumbnailCache.gridMaxPixel)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard imgs.count == sources.count,
              let cg = ImageEditor.composite(imgs, layout: layout, gapFraction: gapFraction,
                                             background: background.cgColor, gridRows: gridRows)
        else { return }
        preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func renderPreview() async {
        renderToken += 1
        let token = renderToken
        rendering = true
        let srcs = sources, lay = layout, gap = gapFraction, bg = background.cgColor, gr = gridRows
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            // Downsample sources for a fast preview (no full-res decode).
            guard let cg = ImageEditor.renderCombined(sources: srcs, layout: lay, gapFraction: gap,
                                                      background: bg, sourceMaxPixel: 900, longEdge: 1400,
                                                      gridRows: gr)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        guard token == renderToken else { return }
        preview = img
        rendering = false
    }

    private func save() {
        busy = true
        let srcs = sources, lay = layout, gap = gapFraction, bg = background.cgColor, gr = gridRows
        let dir = photos[0].url.deletingLastPathComponent()
        let ext = background == .transparent ? "png" : "jpg"
        let dest = ImageEditor.uniqueFileURL(in: dir, base: "Combined", ext: ext)
        let maxPixel = resolution.pixels
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                ImageEditor.combine(sources: srcs, layout: lay, gapFraction: gap,
                                    background: bg, sourceMaxPixel: maxPixel, to: dest, gridRows: gr)
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
