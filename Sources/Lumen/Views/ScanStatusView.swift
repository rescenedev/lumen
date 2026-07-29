import SwiftUI

/// Toolbar readout for a running import — the toolbar is where the eye goes
/// first, so this is the primary indicator; the status bar carries the detail.
///
/// Deliberately UNSTYLED: the toolbar already draws each item on its own
/// capsule, so adding a background here nests a capsule inside a capsule and
/// the item reads as a heavy double ring. Contribute content, let the window
/// chrome own the material — that's what keeps this item looking like it
/// belongs next to the view and sort controls rather than pasted over them.
struct ScanToolbarStatus: View {
    @ObservedObject var scan: ScanMonitor
    var onStop: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(scan.isStopping ? "Stopping" : "Importing")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !scan.isStopping {
                LiveCount(value: scan.found, font: .subheadline.weight(.semibold))
            }
            Button(action: onStop) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                    // Present but recessive until pointed at: always reachable,
                    // never shouting over the count it sits next to.
                    .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(scan.isStopping)
            .help("Stop importing")
            .accessibilityLabel("Stop importing")
            .padding(.leading, 1)
        }
        .onHover { hovering = $0 }
        .animation(ProgressChrome.settle, value: hovering)
    }
}

/// Status-bar row for a running import.
struct ScanStatusView: View {
    @ObservedObject var scan: ScanMonitor
    var onStop: () -> Void

    var body: some View {
        if scan.isScanning {
            StatusRow(label: scan.isStopping ? "Stopping" : "Reading folder",
                      detail: ScanStatusText.counts(found: scan.found, added: scan.added,
                                                    stopping: scan.isStopping),
                      context: scan.folder) {
                // Indeterminate on purpose: while the tree is still being walked
                // there IS no total to divide by, and inventing one would be a
                // lie the user pays for in trust when it jumps.
                ProgressView().controlSize(.mini)
            } trailing: {
                Button("Stop", action: onStop)
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(scan.isStopping)
            }
            .help("Reading the folder you added. Photos appear in the grid as they are found; "
                  + "the total is only known once the whole folder has been read.")
        }
    }
}

/// Full-pane state for an import into a still-empty library — where the old UI
/// left the welcome screen sitting unchanged for the whole (minutes-long) walk.
///
/// One thing is obviously the most important: the count. Everything else is
/// support, ranked by how much the user needs it, and the explanation is one
/// sentence rather than a paragraph.
struct ScanningPlaceholder: View {
    @ObservedObject var scan: ScanMonitor
    var onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 28)

            // Display size wants negative tracking — letters read too far apart
            // as they grow — and tight leading. Rounded digits keep a big number
            // from looking like a receipt.
            LiveCount(value: scan.found,
                      font: .system(size: 64, weight: .semibold, design: .rounded))
                .tracking(-1.5)
                .lineSpacing(0)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 6)

            Text("This can take a few minutes on a NAS.\nPhotos appear as they're found.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 20)

            Button(scan.isStopping ? "Stopping…" : "Stop", action: onStop)
                .controlSize(.large)
                .disabled(scan.isStopping)
                .padding(.top, 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : ProgressChrome.settle, value: scan.isStopping)
    }
}

private extension ScanningPlaceholder {
    var subtitle: String {
        if scan.isStopping { return "finishing the current folder" }
        guard let folder = scan.folder, !folder.isEmpty else { return "photos found so far" }
        return "photos found · \(folder)"
    }
}

/// Pure text builders — unit-tested, so the wording can't silently regress into
/// "Found 0 photos" while a scan is clearly running.
enum ScanStatusText {
    /// The numbers only — the row supplies the label and the folder. A fresh
    /// import has added == found, and "12,480 found · 12,480 new" reads as
    /// noise; the two diverge exactly when some of the photos were already in
    /// the library, which is the case worth spelling out.
    static func counts(found: Int, added: Int, stopping: Bool) -> String {
        if stopping { return "…" }
        if added == found { return "\(found.formatted()) photos" }
        return "\(found.formatted()) found · \(added.formatted()) new"
    }
}
