import SwiftUI

extension Color {
    /// App accent (set via `.tint`). UI stays mostly system; accent for key bits.
    static let lumenAccent = Color(red: 0.42, green: 0.40, blue: 0.98)
}

/// One brand gradient, used sparingly for the hero CTA and the app glyph.
let heroGradient = LinearGradient(
    colors: [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.58, green: 0.36, blue: 0.98)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// The rounded "app glyph" (gradient tile + symbol) reused on onboarding.
struct LumenGlyph: View {
    var size: CGFloat = 72
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(heroGradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .lumenAccent.opacity(0.4), radius: size * 0.18, y: size * 0.08)
    }
}
