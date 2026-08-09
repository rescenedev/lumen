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
            context: Self.context(source: model.exifIndexSource, rate: model.exifIndexRate),
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

    /// Source + throughput, e.g. "NAS · 212/s".
    static func context(source: String, rate: Int) -> String? {
        var parts: [String] = []
        if !source.isEmpty { parts.append(source) }
        if rate > 0 { parts.append("\(rate)/s") }
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
            context: nil,
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
