import SwiftUI

/// Lumen brand tokens (match the landing page: blue → purple → pink on dark).
let brandGradient = LinearGradient(
    colors: [Color(red: 0.36, green: 0.53, blue: 1),
             Color(red: 0.60, green: 0.36, blue: 1),
             Color(red: 1, green: 0.44, blue: 0.68)],
    startPoint: .leading, endPoint: .trailing)

extension Color {
    static let lumenBG = Color(red: 0.027, green: 0.035, blue: 0.063)
}

/// The app's dark, glowing background.
struct LumenBackground: View {
    var body: some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            RadialGradient(colors: [Color(red: 0.36, green: 0.53, blue: 1).opacity(0.16), .clear],
                           center: .topLeading, startRadius: 10, endRadius: 520).ignoresSafeArea()
            RadialGradient(colors: [Color(red: 1, green: 0.44, blue: 0.68).opacity(0.10), .clear],
                           center: .bottomTrailing, startRadius: 10, endRadius: 560).ignoresSafeArea()
        }
    }
}
