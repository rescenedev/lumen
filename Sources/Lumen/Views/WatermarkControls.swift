import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// All watermark state (text caption + image logo), shared by the combine,
/// single-photo editor, and batch flows so the controls live in one place.
struct WatermarkSettings {
    var captionText = ""
    var captionPos: ImageEditor.Caption.Position = .bottomRight
    var captionColor: Color = .white
    var captionHex = "FFFFFF"
    var captionNorm: CGPoint? = nil       // free drag placement (combine preview only)
    var logoImage: CGImage? = nil
    var logoName = ""
    var logoPos: ImageEditor.Caption.Position = .bottomLeft
    var logoSize: Double = 12             // % of canvas short edge
    var logoOpacity: Double = 100         // %

    var caption: ImageEditor.Caption? {
        let t = captionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let cg = NSColor(captionColor).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1)
        return ImageEditor.Caption(text: t, position: captionPos, color: cg,
                                   sizeFraction: 0.045, normPosition: captionNorm)
    }
    var logo: ImageEditor.Logo? {
        guard let logoImage else { return nil }
        return ImageEditor.Logo(image: logoImage, position: logoPos,
                                sizeFraction: CGFloat(logoSize) / 100, opacity: CGFloat(logoOpacity) / 100)
    }
    /// Stable signature for `.task(id:)` so previews re-render when anything changes.
    var renderKey: String {
        "\(captionText)|\(captionPos.rawValue)|\(captionHex)|\(captionNorm?.x ?? -1),\(captionNorm?.y ?? -1)|\(logoName)|\(logoPos.rawValue)|\(logoSize)|\(logoOpacity)"
    }
}

/// Caption controls (text · position · color picker / swatches / hex). One row,
/// no surrounding spacer — the caller places it (toolbar gap, or stacked bar).
struct WatermarkCaptionRow: View {
    @Binding var settings: WatermarkSettings
    var freeDrag = false

    private let swatches: [Color] = [.white, .black, .red, .yellow, .green, .blue]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat").foregroundStyle(.secondary)
            TextField("캡션/워터마크 (선택)", text: $settings.captionText)
                .textFieldStyle(.roundedBorder).frame(width: 200)
            Picker("", selection: $settings.captionPos) {
                ForEach(ImageEditor.Caption.Position.allCases) { Text(wmPositionLabel($0)).tag($0) }
            }
            .labelsHidden().frame(width: 84).disabled(settings.captionText.isEmpty)
            .onChange(of: settings.captionPos) { _, _ in settings.captionNorm = nil }
            if freeDrag, settings.captionNorm != nil {
                Image(systemName: "hand.draw.fill").foregroundStyle(.secondary)
                    .help("미리보기에서 끌어 위치를 정함")
            }
            Text("색").foregroundStyle(.secondary).disabled(settings.captionText.isEmpty)
            ColorPicker("", selection: $settings.captionColor, supportsOpacity: false)
                .labelsHidden().disabled(settings.captionText.isEmpty)
            ForEach(swatches, id: \.self) { c in
                Button { setColor(c) } label: {
                    Circle().fill(c).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(0.4)))
                }.buttonStyle(.plain).disabled(settings.captionText.isEmpty)
            }
            Text("#").foregroundStyle(.secondary)
            TextField("HEX", text: $settings.captionHex)
                .frame(width: 70).textFieldStyle(.roundedBorder).disabled(settings.captionText.isEmpty)
                .onChange(of: settings.captionHex) { _, v in
                    if let c = wmColor(fromHex: v) { settings.captionColor = c }
                }
        }
        .onChange(of: settings.captionColor) { _, c in
            let h = wmHexString(c); if h != settings.captionHex { settings.captionHex = h }
        }
    }

    private func setColor(_ c: Color) { settings.captionColor = c; settings.captionHex = wmHexString(c) }
}

/// Image-logo controls (pick file · position · size · opacity). One row.
struct WatermarkLogoRow: View {
    @Binding var settings: WatermarkSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.plus").foregroundStyle(.secondary)
            if settings.logoImage == nil {
                Button("이미지 워터마크…") { pickLogo() }
            } else {
                Text(settings.logoName).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                Button { settings.logoImage = nil; settings.logoName = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Picker("", selection: $settings.logoPos) {
                    ForEach(ImageEditor.Caption.Position.allCases) { Text(wmPositionLabel($0)).tag($0) }
                }.labelsHidden().frame(width: 90)
                Text("크기").foregroundStyle(.secondary)
                Slider(value: $settings.logoSize, in: 3...40).frame(width: 90)
                Text("투명").foregroundStyle(.secondary)
                Slider(value: $settings.logoOpacity, in: 10...100).frame(width: 90)
            }
        }
    }

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.prompt = "워터마크로 사용"
        guard panel.runModal() == .OK, let url = panel.url,
              let cg = ImageEditor.orientedCGImage(url) else { return }
        settings.logoImage = cg
        settings.logoName = url.lastPathComponent
    }
}

/// The two rows stacked (caption + logo), left-aligned — used by combine & batch.
struct WatermarkBar: View {
    @Binding var settings: WatermarkSettings
    var freeDrag = false

    var body: some View {
        VStack(spacing: 10) {
            HStack { WatermarkCaptionRow(settings: $settings, freeDrag: freeDrag); Spacer() }
            HStack { WatermarkLogoRow(settings: $settings); Spacer() }
        }
    }
}

func wmPositionLabel(_ p: ImageEditor.Caption.Position) -> String {
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

func wmHexString(_ c: Color) -> String {
    guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return "FFFFFF" }
    return String(format: "%02X%02X%02X",
                  Int((ns.redComponent * 255).rounded()),
                  Int((ns.greenComponent * 255).rounded()),
                  Int((ns.blueComponent * 255).rounded()))
}
func wmColor(fromHex raw: String) -> Color? {
    var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255,
                 green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}
