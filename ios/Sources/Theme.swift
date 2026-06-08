import SwiftUI

extension Color {
    /// App accent (set via `.tint`).
    static let lumenAccent = Color(red: 0.42, green: 0.40, blue: 0.98)
    /// Slate dark theme — used everywhere so the home and the organize screen match.
    static let lumenBG = Color(red: 0.07, green: 0.082, blue: 0.105)
    static let lumenCard = Color(red: 0.13, green: 0.145, blue: 0.18)
}

/// Indigo accent gradient — the lone pop of color (glyph heart, primary CTA).
/// Matches the heart in the app icon.
let heroGradient = LinearGradient(
    colors: [Color(red: 0.46, green: 0.50, blue: 1.0), Color(red: 0.40, green: 0.40, blue: 0.98)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// Slate tile gradient — matches the app icon's slate background.
let slateTile = LinearGradient(
    colors: [Color(red: 0.18, green: 0.21, blue: 0.28), Color(red: 0.08, green: 0.095, blue: 0.13)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// The app mark: two stacked photo cards, the front one tilted — a "swipe to
/// organize" motif. Slate tile + indigo heart, mirroring the app icon.
struct LumenGlyph: View {
    var size: CGFloat = 72

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(slateTile)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .overlay {
                ZStack {
                    card.rotationEffect(.degrees(-11)).offset(x: -size * 0.05, y: size * 0.02).opacity(0.5)
                    card.rotationEffect(.degrees(7)).offset(x: size * 0.055, y: -size * 0.01)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: size * 0.14, y: size * 0.07)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
            .fill(.white)
            .frame(width: size * 0.40, height: size * 0.50)
            .overlay(alignment: .bottom) {
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.12, weight: .bold))
                    .foregroundStyle(heroGradient)
                    .padding(.bottom, size * 0.06)
            }
    }
}
