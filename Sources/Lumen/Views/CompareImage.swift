import SwiftUI

/// A simple full-image view (fit, no zoom) used in side-by-side compare mode.
struct CompareImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = nil
            image = await FullImageLoader.shared.image(for: url)
        }
    }
}
