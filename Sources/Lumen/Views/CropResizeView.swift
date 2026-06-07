import SwiftUI

/// Non-destructive crop + resize editor. Saves to a NEW file by default; can
/// overwrite the original only via an explicit, confirmed action.
struct CropResizeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let photo: Photo

    @State private var image: NSImage?
    @State private var pixelSize: CGSize = .zero
    @State private var cropNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect: AspectChoice = .free
    @State private var longEdge: SizeChoice = .original
    @State private var confirmOverwrite = false
    @State private var busy = false

    private var edit: ImageEditor.Edit {
        ImageEditor.Edit(cropNorm: cropNorm == CGRect(x: 0, y: 0, width: 1, height: 1) ? nil : cropNorm,
                         longEdge: longEdge.pixels)
    }
    private var outputSize: CGSize { ImageEditor.outputSize(source: pixelSize, edit: edit) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color.black.opacity(0.25)
                if let image {
                    CropCanvas(image: image, cropNorm: $cropNorm, aspect: aspect.ratio)
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: 360)
            Divider()
            controls
        }
        .frame(width: 760, height: 640)
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
            HStack(spacing: 20) {
                Picker("Crop", selection: $aspect) {
                    ForEach(AspectChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).frame(width: 200)
                .onChange(of: aspect) { _, new in applyAspect(new) }

                Picker("Resize", selection: $longEdge) {
                    ForEach(SizeChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).frame(width: 200)

                Button("Reset crop") { cropNorm = .init(x: 0, y: 0, width: 1, height: 1); aspect = .free }
                    .disabled(cropNorm == CGRect(x: 0, y: 0, width: 1, height: 1))
                Spacer()
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Overwrite Original…") { confirmOverwrite = true }
                    .tint(.red)
                Button("Save as Copy") { save(overwrite: false) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .disabled(busy || image == nil)
        }
        .padding(16)
    }

    private func load() async {
        let url = photo.url
        let loaded = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGSize)? in
            guard let cg = ImageEditor.orientedCGImage(url) else { return nil }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            return (img, CGSize(width: cg.width, height: cg.height))
        }.value
        if let loaded { image = loaded.0; pixelSize = loaded.1 }
    }

    private func applyAspect(_ choice: AspectChoice) {
        guard let ratio = choice.ratio(originalSize: pixelSize) else { return }   // free → nil
        // Fit the largest centered crop of `ratio` (w/h) inside the current image.
        let imgRatio = pixelSize.width / max(1, pixelSize.height)
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio > imgRatio { h = imgRatio / ratio } else { w = ratio / imgRatio }
        cropNorm = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func save(overwrite: Bool) {
        busy = true
        let dest = overwrite ? photo.url : ImageEditor.editedCopyURL(for: photo.url)
        let current = edit
        let src = photo.url
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                if overwrite {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("lumen-edit-\(UUID().uuidString).\(src.pathExtension)")
                    guard ImageEditor.process(source: src, edit: current, to: tmp) else { return false }
                    do { _ = try FileManager.default.replaceItemAt(src, withItemAt: tmp); return true }
                    catch { try? FileManager.default.removeItem(at: tmp); return false }
                }
                return ImageEditor.process(source: src, edit: current, to: dest)
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

enum SizeChoice: String, CaseIterable, Identifiable {
    case original, px4096, px2048, px1024
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Resize: Original"
        case .px4096: return "Resize: 4096 px"
        case .px2048: return "Resize: 2048 px"
        case .px1024: return "Resize: 1024 px"
        }
    }
    var pixels: Int? {
        switch self {
        case .original: return nil
        case .px4096: return 4096
        case .px2048: return 2048
        case .px1024: return 1024
        }
    }
}
