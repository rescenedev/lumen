import SwiftUI

/// Status-bar label for a running import. Observes `ScanMonitor` directly so the
/// scan's progress ticks re-render only this label — never the grid or sidebar.
struct ScanStatusView: View {
    @ObservedObject var scan: ScanMonitor
    var onStop: () -> Void

    var body: some View {
        if scan.isScanning {
            HStack(spacing: 6) {
                // Indeterminate on purpose: while the tree is still being walked
                // there IS no total to divide by — inventing one would be a lie.
                // The determinate bar appears in the phase that has a real
                // denominator (thumbnail warming, see WarmingStatusView).
                ProgressView().controlSize(.mini)
                Text(ScanStatusText.statusBar(found: scan.found, added: scan.added,
                                              folder: scan.folder, stopping: scan.isStopping))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help("Reading the folder you added. Photos appear in the grid as they are found; "
                          + "the total is only known once the whole folder has been read.")
                Button("Stop", action: onStop)
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(scan.isStopping)
            }
        }
    }
}

/// Full-pane state for an import into a still-empty library — the case where the
/// old UI showed the welcome screen for the whole (minutes-long) NAS walk, with
/// no sign that anything was happening.
struct ScanningPlaceholder: View {
    @ObservedObject var scan: ScanMonitor
    var onStop: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(scan.isStopping ? "Stopping…" : "Reading your folder")
                .font(.title3.weight(.medium))

            // The count is the point of this screen — give it real size.
            Text(scan.found.formatted())
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: scan.found)
            Text("photos found so far")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let folder = scan.folder, !folder.isEmpty {
                Label(folder, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text("A large folder on a NAS can take a few minutes. The total is only known "
                 + "once the whole folder has been read — photos appear here as they are found.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 4)

            Button("Stop", action: onStop)
                .disabled(scan.isStopping)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pure text builders — unit-tested, so the wording can't silently regress into
/// "Found 0 photos" while a scan is clearly running.
enum ScanStatusText {
    static func statusBar(found: Int, added: Int, folder: String?, stopping: Bool) -> String {
        if stopping { return "Stopping…" }
        // A fresh import has added == found, and "12,480 found · 12,480 added"
        // reads as noise. The two numbers only diverge when some of the photos
        // were already in the library — which is exactly when it's worth saying.
        var text = added == found
            ? "Reading folder · \(found.formatted()) photos"
            : "Reading folder · \(found.formatted()) found · \(added.formatted()) new"
        if let folder, !folder.isEmpty { text += " · \(folder)" }
        return text
    }
}
