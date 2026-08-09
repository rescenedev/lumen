import SwiftUI

// Thin observing wrappers around `BackgroundJobPopover`.
//
// These exist for a reason that cost a bug: popover content is built from the
// values it is handed, and a popover presented with a snapshot of
// `model.exifIndexDone` never updates — it froze showing the counts from the
// instant it opened ("Idle", 0/s, a bar that never moved, while the job was
// plainly running). A wrapper whose OWN body reads the observable re-evaluates
// as the job progresses; `BackgroundJobPopover` stays a pure value view.

struct MetadataJobPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        BackgroundJobPopover(
            title: "Reading photo metadata",
            currentPath: model.exifIndexCurrentPath,
            done: model.exifIndexDone,
            total: model.exifIndexTotal,
            context: Self.context(source: model.exifIndexSource, rate: model.exifIndexRate,
                                  cached: model.exifIndexCached),
            isRunning: model.isIndexingExif,
            failures: model.failures(.metadata),
            restart: .init(
                title: "Resume",
                help: "Read the photos still missing metadata",
                enabled: !model.isIndexingExif,
                action: { model.ensureExifIndex() }),
            rebuild: .init(
                title: "Re-read All…",
                confirmation: "Re-read metadata for every photo?",
                detail: "Lumen will discard the metadata index and read all "
                        + "\(model.totalCount.formatted()) photos again. On a NAS this can take hours. "
                        + "Nothing is deleted from your library.",
                confirmLabel: "Re-read All",
                action: { model.rebuildMetadataIndex() }),
            onRetry: { model.retryFailures(.metadata) },
            onClear: { model.clearFailures(.metadata) },
            onReveal: { model.revealFailure($0) })
    }

    /// Source, throughput, and how much this pass did NOT have to read.
    /// The last part matters: without it "8,445 of 8,445" on a 64k library
    /// looks like most of the photos went missing.
    static func context(source: String, rate: Int, cached: Int = 0) -> String? {
        var parts: [String] = []
        if !source.isEmpty { parts.append(source) }
        if rate > 0 { parts.append("\(rate)/s") }
        if cached > 0 { parts.append("\(cached.formatted()) already cached") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ThumbnailJobPopover: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var warming: WarmingMonitor

    var body: some View {
        BackgroundJobPopover(
            title: "Building thumbnails",
            currentPath: warming.currentPath,
            done: warming.done,
            total: warming.total,
            context: BackgroundWorkText.pace(rate: warming.rate, eta: warming.eta, place: nil),
            isRunning: warming.remaining > 0,
            failures: model.failures(.thumbnail),
            restart: .init(
                title: "Restart",
                help: "Start the pass again over the thumbnails still missing",
                enabled: true,
                action: { model.restartThumbnailWarming() }),
            rebuild: .init(
                title: "Rebuild All…",
                confirmation: "Rebuild every thumbnail?",
                detail: "Lumen will delete the thumbnail cache and decode every photo again. "
                        + "On a NAS this takes hours, and browsing is slower until it finishes. "
                        + "Your photos are not touched.",
                confirmLabel: "Rebuild All",
                action: { model.rebuildThumbnailCache() }),
            onRetry: { model.retryFailures(.thumbnail) },
            onClear: { model.clearFailures(.thumbnail) },
            onReveal: { model.revealFailure($0) })
    }
}

struct ExportJobPopover: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var export: ExportMonitor

    var body: some View {
        BackgroundJobPopover(
            title: "Exporting \(export.styleLabel.lowercased())",
            currentPath: export.currentName,
            done: export.done,
            total: export.total,
            context: export.failed > 0
                ? "\(export.failed.formatted()) couldn't be exported" : nil,
            isRunning: export.isExporting,
            activity: "Writing",
            showsFailureSection: false,
            failures: [],
            restart: .init(title: export.isStopping ? "Stopping…" : "Stop",
                           help: "Stop the export; files already written are kept",
                           enabled: !export.isStopping,
                           action: { model.cancelExport() }),
            rebuild: .init(title: "", confirmation: "", detail: "",
                           confirmLabel: "", action: {}),
            onRetry: {}, onClear: {}, onReveal: { _ in })
    }
}

/// Status-bar row for a running export.
struct ExportStatusView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var export: ExportMonitor

    var body: some View {
        if export.isExporting {
            StatusRowButton {
                StatusRow(label: export.isStopping ? "Stopping" : "Exporting",
                          detail: BackgroundWorkText.counts(done: export.done, total: export.total),
                          context: export.currentName,
                          failures: export.failed) {
                    ThinProgressBar(fraction: export.fraction)
                }
            } detail: {
                ExportJobPopover(export: export)
            }
            .help("Writing your export. Photos stored only in iCloud are downloaded first, "
                  + "so this can take a while. Click for details.")
        }
    }
}
