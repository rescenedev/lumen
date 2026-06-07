import SwiftUI

/// Batch-rename sheet. The pattern uses `{n}` for an incrementing number.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var pattern = "Photo {n}"
    @State private var startIndex = 1

    private var targets: [Photo] { model.renameTargets }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename \(targets.count) \(targets.count == 1 ? "Photo" : "Photos")")
                .font(.headline)

            Form {
                TextField("Name pattern", text: $pattern)
                    .help("Use {n} for a sequential number")
                Stepper("Start number: \(startIndex)", value: $startIndex, in: 0...100000)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Preview").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(previews.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.rename(targets, pattern: pattern, startIndex: startIndex)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var previews: [String] {
        let sorted = model.sortOrder.sorted(targets)
        return sorted.prefix(3).enumerated().map { offset, photo in
            let ext = photo.url.pathExtension
            let base = pattern.replacingOccurrences(of: "{n}", with: String(startIndex + offset))
            return ext.isEmpty ? base : "\(base).\(ext)"
        }
    }
}
