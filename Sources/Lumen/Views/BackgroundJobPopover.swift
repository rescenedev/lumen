import SwiftUI

/// Everything the one-line status row has no room for: exactly which file the
/// job is on, and which photos it could not process — with a way to run them
/// again. The row is a button that opens this.
struct BackgroundJobPopover: View {
    /// A plain "run it again" action.
    struct RestartAction {
        var title: String
        var help: String
        var enabled: Bool
        var action: () -> Void
    }

    /// The heavy one: throw the cached results away and start from zero. Costs
    /// hours on a NAS, so unlike everything else here it asks first.
    struct RebuildAction {
        var title: String
        var confirmation: String
        var detail: String
        var confirmLabel: String
        var action: () -> Void
    }

    let title: String
    /// Live position: what it's reading right now, nil when idle.
    let currentPath: String?
    let done: Int
    let total: Int
    /// Source / throughput, e.g. "NAS · 212/s".
    let context: String?
    let isRunning: Bool
    /// What the job is doing to the current item — "Reading" for the index,
    /// "Writing" for an export.
    var activity: String = "Reading"
    /// Export tracks its failures as a running count, not a list; showing the
    /// list's "No photos have failed" next to "3 couldn't be exported" would
    /// contradict itself.
    var showsFailureSection = true
    let failures: [JobFailure]
    let restart: RestartAction
    let rebuild: RebuildAction
    var onRetry: () -> Void
    var onClear: () -> Void
    var onReveal: (JobFailure) -> Void

    @State private var confirmingRebuild = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !failures.isEmpty {
                failureList
                Divider()
            } else if showsFailureSection {
                noFailures
                Divider()
            }
            footer
        }
        .frame(width: 420)
        .confirmationDialog(rebuild.confirmation, isPresented: $confirmingRebuild) {
            Button(rebuild.confirmLabel, role: .destructive, action: rebuild.action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(rebuild.detail)
        }
    }

    // MARK: Header — where it is right now

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if total > 0 {
                    Text(BackgroundWorkText.counts(done: done, total: total))
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if total > 0 {
                ThinProgressBar(fraction: Double(done) / Double(max(total, 1)), width: 388)
            }
            if let currentPath {
                LabeledPath(caption: activity, path: currentPath)
            } else {
                // "Idle" is only honest when nothing is running. A job that has
                // started but not yet reported a file is starting, not idle.
                Text(isRunning ? "Starting…" : "Idle")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if let context, !context.isEmpty {
                Text(context).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(14)
    }

    // MARK: Failures

    private var noFailures: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
            Text("No photos have failed.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(failures.count.formatted()) failed")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            ScrollView {
                // A plain VStack, not Lazy: the log is capped at 300 entries, and
                // a lazy stack only materialises rows once it has real scroll
                // bounds — which costs correctness (empty popover in offscreen
                // rendering) for a saving that does not exist at this size.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(failures) { failure in
                        FailureRow(failure: failure) { onReveal(failure) }
                        Divider().padding(.leading, 14)
                    }
                }
            }
            // Tall enough to scan a handful, short enough that the popover stays
            // a popover. `.fixedSize(vertical:)` first so a short list sizes to
            // its content instead of the ScrollView greedily taking the cap.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 220)
        }
    }

    /// Ordered by how much they cost the user: the cheap, common action on the
    /// right where the eye lands, the expensive one tucked left behind a
    /// confirmation.
    private var footer: some View {
        HStack(spacing: 8) {
            if !rebuild.title.isEmpty {
                Button(rebuild.title) { confirmingRebuild = true }
                    .help("Discard what has been built and start from zero")
            }
            Spacer()
            if !failures.isEmpty {
                Button("Clear", action: onClear)
                    .help("Forget these records without retrying")
                Button("Retry \(failures.count.formatted())", action: onRetry)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(restart.title, action: restart.action)
                    .disabled(!restart.enabled)
                    .help(restart.help)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// One failed photo: name, why, and where.
private struct FailureRow: View {
    let failure: JobFailure
    var onReveal: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(failure.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !failure.folder.isEmpty {
                        Text("· \(failure.folder)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 8)
            Button(action: onReveal) {
                Image(systemName: "arrow.up.forward.app")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
        .help(failure.path)
    }
}

/// A path shown head-truncated, so the filename — the part that identifies it —
/// always survives while the long NAS prefix is what gets cut.
private struct LabeledPath: View {
    let caption: String
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(caption)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(path)
        }
    }
}
