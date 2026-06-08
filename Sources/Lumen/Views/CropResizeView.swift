import SwiftUI

/// Non-destructive crop + resize editor. Saves to a NEW file by default; can
/// overwrite the original only via an explicit, confirmed action.
struct CropResizeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let photo: Photo

    @State private var image: NSImage?
    @State private var baseCG: CGImage?            // upright, downsampled — re-transformed on rotate/flip/straighten
    @State private var pixelSize: CGSize = .zero
    @State private var straighten: Double = 0      // fine angle, degrees
    @State private var displayToken = 0
    @State private var cropNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect: AspectChoice = .free
    @State private var lockRatio = false
    @State private var lockedRatio: CGFloat?       // fixed at lock time so dragging can't drift it
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var padBackground: PadBackground = .white
    @State private var contentAlign = CGPoint(x: 0.5, y: 0.5)   // image position within a padded canvas
    @State private var rotationQuarters = 0
    @State private var flipH = false
    @State private var zoom: CGFloat = 1
    @State private var watermark = WatermarkSettings()
    @State private var confirmOverwrite = false
    @State private var busy = false

    /// Fill most of the screen so the crop can be placed precisely.
    private var windowSize: CGSize {
        let vis = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(vis.width * 0.94, 2000), height: min(vis.height * 0.94, 1400))
    }

    private func px(_ text: String) -> Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }
    private var targetWidth: Int? { px(widthText) }
    private var targetHeight: Int? { px(heightText) }
    /// A missing axis mirrors the other → a single value makes a square canvas.
    /// Any value at all means "canvas mode" (exact size, fit + pad + draggable).
    private var canvasTarget: (w: Int, h: Int)? {
        switch (targetWidth, targetHeight) {
        case (nil, nil): return nil
        case let (w?, nil): return (w, w)
        case let (nil, h?): return (h, h)
        case let (w?, h?): return (w, h)
        }
    }
    private var isCanvas: Bool { canvasTarget != nil }
    /// RAW/webp/etc. can be edited but only saved as JPG (a new file); the
    /// original is never overwritten so the master stays intact.
    private var canOverwrite: Bool { ImageEditor.canOverwrite(photo.url) }
    private var saveAsLabel: String { canOverwrite ? "Save as Copy" : "Save as Copy (JPG)" }

    private var edit: ImageEditor.Edit {
        ImageEditor.Edit(cropNorm: cropNorm == CGRect(x: 0, y: 0, width: 1, height: 1) ? nil : cropNorm,
                         targetWidth: canvasTarget?.w, targetHeight: canvasTarget?.h,
                         rotationQuarters: rotationQuarters, straightenDegrees: straighten, flipH: flipH,
                         contentAlign: contentAlign)
    }
    /// Scale of the saved image content relative to the on-screen crop (≤1), used
    /// to draw the size-preview box. nil when no resize is active or it's ~full.
    private var indicatorScale: CGFloat? {
        guard let t = canvasTarget else { return nil }
        let s = rotatedPixelSize
        let cw = s.width * cropNorm.width, ch = s.height * cropNorm.height
        guard cw > 0, ch > 0 else { return nil }
        let k = min(CGFloat(t.w) / cw, CGFloat(t.h) / ch, 1)
        return k < 0.999 ? k : nil
    }
    private var indicatorLabel: String { "\(Int(outputSize.width))×\(Int(outputSize.height))" }

    /// The crop's current pixel aspect ratio (w/h) in the rotated image.
    private var currentCropRatio: CGFloat? {
        let s = rotatedPixelSize
        let w = cropNorm.width * s.width, h = cropNorm.height * s.height
        return h > 0 ? w / h : nil
    }
    private var outputSize: CGSize { ImageEditor.outputSize(source: pixelSize, edit: edit) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color.black.opacity(0.25)
                if let image {
                    CropCanvas(image: image, cropNorm: $cropNorm, aspect: lockRatio ? lockedRatio : nil,
                               indicatorScale: indicatorScale, indicatorLabel: indicatorLabel,
                               indicatorAnchor: $contentAlign, indicatorDraggable: isCanvas, zoom: $zoom,
                               caption: watermark.caption, logo: watermark.logo)
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: 360)
            Divider()
            controls
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .task(id: photo.url) { await load() }
        .alert("Overwrite the original?", isPresented: $confirmOverwrite) {
            Button("Overwrite", role: .destructive) { save(overwrite: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(photo.filename)” will be replaced with the edited image. This can’t be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text("Edit · \(photo.filename)").font(.headline).lineLimit(1)
            Spacer()
            if pixelSize != .zero {
                Text("\(Int(pixelSize.width))×\(Int(pixelSize.height)) → \(Int(outputSize.width))×\(Int(outputSize.height))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            // One toolbar row: crop · rotate/straighten · resize · watermark · zoom · reset.
            HStack(spacing: 12) {
                Picker("Crop", selection: $aspect) {
                    ForEach(AspectChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).frame(width: 150)
                .onChange(of: aspect) { _, new in
                    if new == .free { lockRatio = false; lockedRatio = nil }
                    else { applyAspect(new); lockedRatio = new.ratio(originalSize: rotatedPixelSize); lockRatio = true }
                }

                Toggle(isOn: $lockRatio) {
                    Image(systemName: lockRatio ? "lock.fill" : "lock.open")
                }
                .toggleStyle(.button).help("비율 고정/해제")
                .onChange(of: lockRatio) { _, on in lockedRatio = on ? currentCropRatio : nil }

                HStack(spacing: 4) {
                    Button { rotate(-1) } label: { Image(systemName: "rotate.left") }
                    Button { rotate(1) } label: { Image(systemName: "rotate.right") }
                    Button { flipH.toggle(); refreshDisplay() } label: { Image(systemName: "trapezoid.and.line.vertical") }
                        .background(flipH ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .help("Rotate / flip")

                HStack(spacing: 6) {
                    Image(systemName: "level").foregroundStyle(.secondary)
                    Slider(value: $straighten, in: -15...15) { editing in
                        if !editing { refreshDisplay() }       // settle to a crisp render on release
                    }
                    .frame(width: 110)
                    .onChange(of: straighten) { _, _ in refreshDisplay() }
                    Text(String(format: "%+.1f°", straighten)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).fixedSize().frame(width: 42, alignment: .trailing)
                        .onTapGesture { straighten = 0; refreshDisplay() }
                }

                Text("Resize").foregroundStyle(.secondary).fixedSize()
                TextField("자동", text: $widthText)
                    .frame(width: 58).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                Text("×").foregroundStyle(.secondary)
                TextField("자동", text: $heightText)
                    .frame(width: 58).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                Text("px").foregroundStyle(.secondary).fixedSize()
                if isCanvas {
                    Picker("", selection: $padBackground) {
                        ForEach(PadBackground.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 110).help("여백 배경")
                }

                Spacer(minLength: 12)
                WatermarkCaptionRow(settings: $watermark)
                WatermarkLogoRow(settings: $watermark)
                Spacer(minLength: 12)

                HStack(spacing: 4) {
                    Button { zoom = max(1, zoom / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                    Text(String(format: "%.0f%%", zoom * 100)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 40).onTapGesture { zoom = 1 }
                    Button { zoom = min(8, zoom * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
                }
                Button("Reset") {
                    cropNorm = .init(x: 0, y: 0, width: 1, height: 1); aspect = .free; lockRatio = false
                    rotationQuarters = 0; flipH = false; straighten = 0; widthText = ""; heightText = ""
                    contentAlign = CGPoint(x: 0.5, y: 0.5); zoom = 1; refreshDisplay()
                }
                .disabled(cropNorm == CGRect(x: 0, y: 0, width: 1, height: 1)
                          && rotationQuarters == 0 && !flipH && straighten == 0
                          && widthText.isEmpty && heightText.isEmpty)
            }
            HStack(spacing: 12) {
                if !canOverwrite {
                    Text("RAW 등은 편집본을 JPG로 저장합니다 (원본 보존)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if canOverwrite {
                    Button("Overwrite Original…") { confirmOverwrite = true }.tint(.red)
                }
                Button(saveAsLabel) { save(overwrite: false) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .disabled(busy || image == nil)
        }
        .padding(16)
    }

    private func load() async {
        let url = photo.url
        let cg = await Task.detached(priority: .userInitiated) { ImageEditor.orientedCGImage(url) }.value
        guard let cg else { return }
        pixelSize = CGSize(width: cg.width, height: cg.height)
        // A light base so re-transforming on every straighten tick stays smooth;
        // the saved output still re-reads and processes the full-res source.
        baseCG = await Task.detached(priority: .userInitiated) { ImageEditor.downsampled(cg, maxPixel: 2200) }.value
        refreshDisplay()
    }

    /// Rotate by ±90°; rotating changes the image frame, so reset the crop to the
    /// full (rotated) image to avoid a now-meaningless rectangle.
    private func rotate(_ delta: Int) {
        rotationQuarters = ((rotationQuarters + delta) % 4 + 4) % 4
        cropNorm = .init(x: 0, y: 0, width: 1, height: 1)
        aspect = .free
        refreshDisplay()
    }

    /// Re-render the canvas image from the base using the SAME transforms the save
    /// path uses, so preview and output never disagree. A token drops stale renders.
    private func refreshDisplay() {
        guard let baseCG else { return }
        displayToken += 1
        let token = displayToken
        let q = rotationQuarters, f = flipH, deg = straighten
        Task {
            let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                var t = ImageEditor.transformed(baseCG, quarters: q, flipH: f) ?? baseCG
                if deg != 0, let s = ImageEditor.straightened(t, degrees: deg) { t = s }
                return NSImage(cgImage: t, size: NSSize(width: t.width, height: t.height))
            }.value
            if token == displayToken, let img { image = img }
        }
    }

    /// Image dimensions as currently displayed (rotation swaps them; straighten
    /// auto-crops them) — the space `cropNorm` is normalized against.
    private var rotatedPixelSize: CGSize {
        var s = rotationQuarters % 2 != 0 ? CGSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
        if straighten != 0 { s = ImageEditor.straightenCropSize(s.width, s.height, degrees: straighten) }
        return s
    }

    private func applyAspect(_ choice: AspectChoice) {
        let size = rotatedPixelSize
        guard let ratio = choice.ratio(originalSize: size) else { return }   // free → nil
        // Fit the largest centered crop of `ratio` (w/h) inside the current image.
        let imgRatio = size.width / max(1, size.height)
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio > imgRatio { h = imgRatio / ratio } else { w = ratio / imgRatio }
        cropNorm = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func save(overwrite: Bool) {
        busy = true
        let dest = overwrite ? photo.url : ImageEditor.editedCopyURL(for: photo.url)
        let current = edit
        let src = photo.url
        let bg = padBackground.cgColor
        let cap = watermark.caption, lg = watermark.logo
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                if overwrite {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("lumen-edit-\(UUID().uuidString).\(src.pathExtension)")
                    guard ImageEditor.process(source: src, edit: current, to: tmp, background: bg,
                                              caption: cap, logo: lg) else { return false }
                    do { _ = try FileManager.default.replaceItemAt(src, withItemAt: tmp); return true }
                    catch { try? FileManager.default.removeItem(at: tmp); return false }
                }
                return ImageEditor.process(source: src, edit: current, to: dest, background: bg,
                                           caption: cap, logo: lg)
            }.value
            busy = false
            if ok {
                model.didEdit(source: src, output: dest, overwrote: overwrite)
                dismiss()
            } else {
                model.showToast("Couldn’t save the edited image.")
            }
        }
    }
}

// MARK: - Choices

/// Fill for the margins when the output canvas is larger than the image.
enum PadBackground: String, CaseIterable, Identifiable {
    case white, black, transparent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .white: return "여백: 흰색"
        case .black: return "여백: 검정"
        case .transparent: return "여백: 투명"
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

enum AspectChoice: String, CaseIterable, Identifiable {
    case free, original, square, r43, r169, r32
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: return "Crop: Freeform"
        case .original: return "Crop: Original"
        case .square: return "Crop: 1:1"
        case .r43: return "Crop: 4:3"
        case .r169: return "Crop: 16:9"
        case .r32: return "Crop: 3:2"
        }
    }
    /// Desired width/height ratio, or nil for freeform.
    var ratio: CGFloat? {
        switch self {
        case .free, .original: return nil
        case .square: return 1
        case .r43: return 4.0 / 3.0
        case .r169: return 16.0 / 9.0
        case .r32: return 3.0 / 2.0
        }
    }
    func ratio(originalSize: CGSize) -> CGFloat? {
        if self == .original, originalSize.height > 0 { return originalSize.width / originalSize.height }
        return ratio
    }
}

