import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

/// Minimal on-device proof that the shared `ImageEditor` engine works on iOS:
/// pick a few photos → combine them (strip / grid) with an optional caption →
/// save the result to the photo library. No macOS/AppKit code involved.
struct CombineDemoView: View {
    @State private var picks: [PhotosPickerItem] = []
    @State private var sources: [CGImage] = []
    @State private var layout: ImageEditor.CombineLayout = .horizontal
    @State private var caption = ""
    @State private var result: UIImage?
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PhotosPicker(selection: $picks, maxSelectionCount: 9, matching: .images) {
                        Label(sources.isEmpty ? "사진 선택" : "사진 \(sources.count)장 · 다시 선택",
                              systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity).padding().background(.thinMaterial, in: .rect(cornerRadius: 12))
                    }

                    Picker("레이아웃", selection: $layout) {
                        Text("가로").tag(ImageEditor.CombineLayout.horizontal)
                        Text("세로").tag(ImageEditor.CombineLayout.vertical)
                        Text("그리드").tag(ImageEditor.CombineLayout.grid)
                    }.pickerStyle(.segmented)

                    TextField("캡션 (선택)", text: $caption).textFieldStyle(.roundedBorder)

                    Button("합치기") { combine() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || sources.count < 2)

                    if let result {
                        Image(uiImage: result).resizable().scaledToFit()
                            .frame(maxHeight: 380).clipShape(.rect(cornerRadius: 12))
                        Button("사진에 저장") {
                            UIImageWriteToSavedPhotosAlbum(result, nil, nil, nil)
                            status = "저장됨 ✓"
                        }
                    }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                .padding()
            }
            .navigationTitle("Lumen · Combine")
            .onChange(of: picks) { _, items in Task { await load(items) } }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var imgs: [CGImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let cg = Self.decode(data, maxPixel: 2000) {
                imgs.append(cg)
            }
        }
        sources = imgs
        result = nil
        status = ""
    }

    private func combine() {
        busy = true
        let imgs = sources, lay = layout
        let cap: ImageEditor.Caption? = caption.isEmpty ? nil
            : .init(text: caption, position: .bottomRight, color: CGColor(gray: 1, alpha: 1), sizeFraction: 0.05)
        Task {
            let cg = await Task.detached {
                ImageEditor.composite(imgs, layout: lay, gapFraction: 0.012,
                                      background: CGColor(gray: 1, alpha: 1), longEdge: 2400, caption: cap)
            }.value
            busy = false
            result = cg.map { UIImage(cgImage: $0) }
            status = cg == nil ? "합치기 실패 (2장 이상 필요)" : ""
        }
    }

    /// Decode picked image data to an oriented, downsampled CGImage.
    private static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
