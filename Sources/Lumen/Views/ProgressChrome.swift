import SwiftUI

/// Shared building blocks for the app's background-activity chrome (import
/// scan, thumbnail warming, EXIF indexing) so the three read as one family
/// instead of three ad-hoc arrangements of a spinner and some text.
enum ProgressChrome {
    /// One deliberate spacing scale, so nothing is an arbitrary number.
    static let tightGap: CGFloat = 6
    static let barWidth: CGFloat = 88
    static let barHeight: CGFloat = 4

    /// Critically damped — these values are reported, not thrown, so overshoot
    /// would be noise. (Bounce is earned by momentum, and there is none here.)
    static let settle = Animation.spring(response: 0.35, dampingFraction: 1)
}

/// A slim capsule bar. The stock `ProgressView(.linear)` is a chunky full-width
/// control built for sheets; inline status chrome wants something quieter that
/// reads as a measure, not a widget.
struct ThinProgressBar: View {
    var fraction: Double
    var width: CGFloat = ProgressChrome.barWidth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule(style: .continuous)
            .fill(.quaternary)
            .frame(width: width, height: ProgressChrome.barHeight)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    // Never zero-width: a sliver reads as "started", where an
                    // empty track reads as "nothing is happening".
                    .frame(width: max(ProgressChrome.barHeight, width * clamped),
                           height: ProgressChrome.barHeight)
            }
            .animation(reduceMotion ? nil : ProgressChrome.settle, value: clamped)
            .accessibilityHidden(true)   // the adjacent label carries the value
    }
}

/// A count that animates digit-by-digit as it climbs. Monospaced so the row
/// doesn't twitch sideways every time a digit changes.
struct LiveCount: View {
    var value: Int
    var font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(value.formatted())
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : ProgressChrome.settle, value: value)
    }
}

/// The status-bar row shape shared by every background job: a leading indicator,
/// a quiet label, the numbers, then the place it's working on.
struct StatusRow<Indicator: View, Trailing: View>: View {
    var label: String
    var detail: String
    var context: String?
    @ViewBuilder var indicator: Indicator
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: ProgressChrome.tightGap) {
            indicator
            // Weight, not size, carries the hierarchy — the row has to stay
            // 28pt tall no matter what it says.
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let context, !context.isEmpty {
                Text(context)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            trailing
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension StatusRow where Trailing == EmptyView {
    init(label: String, detail: String, context: String?,
         @ViewBuilder indicator: () -> Indicator) {
        self.init(label: label, detail: detail, context: context,
                  indicator: indicator, trailing: { EmptyView() })
    }
}
