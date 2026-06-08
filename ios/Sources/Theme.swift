import SwiftUI

extension Color {
    /// App accent (set via `.tint`).
    static let lumenAccent = Color(red: 0.42, green: 0.40, blue: 0.98)
    /// Slate dark theme — used everywhere so the home and the organize screen match.
    static let lumenBG = Color(red: 0.07, green: 0.082, blue: 0.105)
    static let lumenCard = Color(red: 0.13, green: 0.145, blue: 0.18)
}

/// One brand gradient, used sparingly for the app glyph / onboarding CTA.
let heroGradient = LinearGradient(
    colors: [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.58, green: 0.36, blue: 0.98)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// The app mark: two stacked photo cards, the front one tilted — a "swipe to
/// organize" motif.
struct LumenGlyph: View {
    var size: CGFloat = 72

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(heroGradient)
            .frame(width: size, height: size)
            .overlay {
                ZStack {
                    card.rotationEffect(.degrees(-11)).offset(x: -size * 0.05, y: size * 0.02).opacity(0.55)
                    card.rotationEffect(.degrees(7)).offset(x: size * 0.055, y: -size * 0.01)
                }
            }
            .shadow(color: .lumenAccent.opacity(0.4), radius: size * 0.16, y: size * 0.07)
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
