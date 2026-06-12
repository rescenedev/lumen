import SwiftUI

/// Timeline of metadata-organizing actions (rate, favorite, label, tag,
/// reject), newest first, each revertible. Photo files are never part of this
/// — only Lumen-owned metadata, so reverting can never lose a photo.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    // Snapshot taken on appear and after each revert (this is a sheet, not a
    // live grid — no need to observe).
    @State private var entries: [OperationLogEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Organize History", systemImage: "clock.arrow.circlepath")
                    .font(.title2.bold())
                Spacer()
                if !entries.isEmpty {
                    Button("Clear", role: .destructive) {
                        model.clearOperationHistory()
                        reload()
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 6)

            Text("Tag, rating, favorite, label, and reject changes — revert any of them. Your photo files are never touched.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.bottom, 14)

            if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No history yet").font(.title3.weight(.medium))
                    Text("Rate, favorite, label, or tag photos and the actions show up here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .onAppear(perform: reload)
    }

    private func row(_ entry: OperationLogEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(entry.undone ? .tertiary : .secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                    .font(.body.weight(.medium))
                    .strikethrough(entry.undone)
                    .foregroundStyle(entry.undone ? .secondary : .primary)
                Text("\(entry.affectedCount) photo\(entry.affectedCount == 1 ? "" : "s") · \(Self.relative(entry.date))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            if entry.undone {
                Text("Reverted").font(.caption).foregroundStyle(.tertiary)
            } else if entry.affectedCount > 0 {
                Button("Revert") {
                    model.undoOperation(entry.id)
                    reload()
                }
                .controlSize(.small)
            } else {
                Text("Too large").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
    }

    private func reload() { entries = model.operationHistory() }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
