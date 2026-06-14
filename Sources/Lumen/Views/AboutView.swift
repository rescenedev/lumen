import SwiftUI

/// Custom About panel — app icon, version, tagline, and links.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Lumen").font(.system(size: 30, weight: .bold))
            Text("Version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("A fast, non-destructive viewer & manager for large photo libraries — local, NAS, and Apple Photos.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                Link("Website", destination: URL(string: "https://rescenedev.github.io/lumen")
                    ?? URL(fileURLWithPath: "/"))
                Link("GitHub", destination: URL(string: "https://github.com/rescenedev/lumen")
                    ?? URL(fileURLWithPath: "/"))
            }
            .font(.callout)
            .padding(.top, 2)

            Text("© 2026 rescenedev · MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 34)
        .frame(width: 440)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
