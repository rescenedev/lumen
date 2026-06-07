import SwiftUI

/// Onboarding shown when no photos have been imported yet.
struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Welcome to Lumen")
                    .font(.largeTitle.bold())
                Text("A fast, read-only viewer for your photo library.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)

                Button {
                    model.selectedSidebar = .photosLibrary
                } label: {
                    Label("Browse Apple Photos", systemImage: "photo.stack")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            Text("…or drag images and folders anywhere in this window")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(24)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.importURLs(urls) }
        return true
    }
}
