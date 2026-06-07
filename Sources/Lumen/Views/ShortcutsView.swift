import SwiftUI

/// Keyboard-shortcut cheat sheet (⌘/). Lumen targets power users, so the
/// shortcuts should be discoverable.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }
    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let items: [Shortcut]
    }

    private let sections: [Section] = [
        Section(title: "Library", items: [
            .init(keys: "⌘O", action: "Add folder or photos"),
            .init(keys: "⌘F", action: "Search"),
            .init(keys: "⌘A", action: "Select all"),
            .init(keys: "Esc", action: "Clear selection"),
            .init(keys: "⌫", action: "Move to Trash"),
        ]),
        Section(title: "View", items: [
            .init(keys: "⌘1 / ⌘2 / ⌘3", action: "Grid / List / Map"),
            .init(keys: "⌘ + / ⌘ –", action: "Larger / smaller thumbnails"),
            .init(keys: "Space", action: "Quick Look (in grid)"),
            .init(keys: "Return", action: "Open in viewer"),
        ]),
        Section(title: "Cull (grid)", items: [
            .init(keys: "1–5", action: "Rate selected"),
            .init(keys: "0", action: "Clear rating"),
            .init(keys: "F", action: "Toggle favorite"),
            .init(keys: "X", action: "Toggle reject"),
        ]),
        Section(title: "Viewer", items: [
            .init(keys: "← / →", action: "Previous / next photo"),
            .init(keys: "Space", action: "Favorite & advance"),
            .init(keys: "F", action: "Toggle favorite"),
            .init(keys: "X", action: "Reject & advance"),
            .init(keys: "1–5", action: "Set rating"),
            .init(keys: "I", action: "Toggle EXIF overlay"),
            .init(keys: "P", action: "Slideshow"),
            .init(keys: "= / – / 0", action: "Zoom in / out / reset"),
            .init(keys: "⌫", action: "Move to Trash"),
            .init(keys: "Esc", action: "Close viewer"),
        ]),
        Section(title: "App", items: [
            .init(keys: "⌘,", action: "Settings"),
            .init(keys: "⌘/", action: "This shortcuts list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 16)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top),
                                    GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 22) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(section.items) { item in
                                HStack(spacing: 10) {
                                    Text(item.keys)
                                        .font(.system(.body, design: .rounded).weight(.medium))
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                        .frame(minWidth: 96, alignment: .leading)
                                    Text(item.action)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 540)
    }
}
