import SwiftUI
import AppKit

/// Resize / canvas-pad a batch of photos and export copies to a chosen folder.
/// Non-destructive: originals are untouched. A single value makes a square
/// canvas (mirrors the empty axis), matching the single-photo editor.
struct BatchResizeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let photos: [Photo]

    @State private var widthText = ""
    @State private var heightText = ""
    @State private var background: PadBackground = .white
    @State private var format: BatchProcessor.Format = .jpg
    @State private var quality: Double = 0.9
    @State private var watermark = WatermarkSettings()
    @State private var running = false
    @State private var done = 0

    private func px(_ t: String) -> Int? {
        guard let n = Int(t.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }
    /// A missing axis mirrors the other → single value = square canvas.
    private var canvasTarget: (w: Int, h: Int)? {
        switch (px(widthText), px(heightText)) {
        case (nil, nil): return nil
        case let (w?, nil): return (w, w)
        case let (nil, h?): return (h, h)
        case let (w?, h?): return (w, h)
        }
    }
    private var sizeSummary: String {
        if let t = canvasTarget { return "각 사진 → \(t.w)×\(t.h) 캔버스 (여백 채움)" }
        return "원본 크기 유지 (포맷만 변환)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Batch Resize · \(photos.count) Photos").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("Resize").foregroundStyle(.secondary)
                    TextField("자동", text: $widthText)
                        .frame(width: 64).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                    Text("×").foregroundStyle(.secondary)
                    TextField("자동", text: $heightText)
                        .frame(width: 64).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
                Text(sizeSummary).font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    if canvasTarget != nil {
                        Picker("여백", selection: $background) {
                            ForEach(PadBackground.allCases) { Text($0.label).tag($0) }
                        }.frame(width: 190)
                    }
                    Picker("포맷", selection: $format) {
                        ForEach(BatchProcessor.Format.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 130)
                    if format == .jpg {
                        Text("품질").foregroundStyle(.secondary)
                        Slider(value: $quality, in: 0.4...1).frame(width: 110)
                        Text("\(Int(quality * 100))").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 28)
                    }
                    Spacer()
                }

                Divider()
                WatermarkBar(settings: $watermark)

                if running {
                    ProgressView(value: Double(done), total: Double(photos.count)) {
                        Text("내보내는 중… \(done)/\(photos.count)").font(.caption)
                    }
                }
            }
            .padding(16)

            Divider()
            HStack {
                Text("원본은 변경되지 않습니다").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                Button("폴더 선택 후 내보내기") { chooseAndRun() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(running)
            }
            .padding(16)
        }
        .frame(width: 660, height: 440)
    }

    private func chooseAndRun() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "여기에 내보내기"
        panel.message = "리사이즈한 사본을 저장할 폴더를 선택하세요."
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        running = true; done = 0
        let urls = photos.map(\.url)
        let edit = ImageEditor.Edit(cropNorm: nil, targetWidth: canvasTarget?.w, targetHeight: canvasTarget?.h)
        let fmt = format, q = CGFloat(quality), bg = background.cgColor
        let cap = watermark.caption, lg = watermark.logo
        Task {
            let count = await Task.detached(priority: .userInitiated) {
                BatchProcessor.run(urls, edit: edit, format: fmt, quality: q, background: bg, into: dir,
                                   caption: cap, logo: lg) { d, _ in
                    Task { @MainActor in done = d }
                }
            }.value
            running = false
            model.didBatchResize(count: count, folder: dir)
            dismiss()
        }
    }
}
