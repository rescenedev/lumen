import SwiftUI

/// App settings — kept deliberately tiny: support/source/policy/contact/version.
/// Hidden by design: pull the home screen down to reveal it (a gear hint rides
/// in with the pull, so it's discoverable without spending a button).
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let sponsorURL = URL(string: "https://fairy.hada.io/@lumen")!
    static let privacyURL = URL(string: "https://rescenedev.github.io/lumen/lumen-ios/privacy.html")!
    static let contactURL = URL(string: "mailto:tellme@duck.com?subject=Lumen%20iOS")!
    static let sourceURL = URL(string: "https://github.com/rescenedev/lumen-ios")!

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("설정").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)

            row("heart.fill", "개발자 응원하기") { UIApplication.shared.open(Self.sponsorURL) }
            divider
            row("chevron.left.forwardslash.chevron.right", "오픈소스 (MIT)") { UIApplication.shared.open(Self.sourceURL) }
            divider
            row("hand.raised.fill", "개인정보처리방침") { UIApplication.shared.open(Self.privacyURL) }
            divider
            row("envelope.fill", "문의하기") { UIApplication.shared.open(Self.contactURL) }
            divider

            HStack {
                Label { Text("버전").font(.body.weight(.medium)).foregroundStyle(.white) }
                icon: { Image(systemName: "info.circle.fill").foregroundStyle(.white.opacity(0.5)).frame(width: 28) }
                Spacer()
                Text(version).font(.body.monospacedDigit()).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 22).padding(.vertical, 16)

            Spacer(minLength: 0)

            Text("Lumen은 무료입니다. 모든 사진 처리는 기기 안에서만 이루어집니다.")
                .font(.footnote).foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(446)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.lumenCard)
        .preferredColorScheme(.dark)
    }

    private var divider: some View {
        Divider().overlay(.white.opacity(0.07)).padding(.leading, 22)
    }

    private func row(_ icon: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label { Text(title).font(.body.weight(.medium)).foregroundStyle(.white) }
                icon: { Image(systemName: icon).foregroundStyle(.white.opacity(0.5)).frame(width: 28) }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
