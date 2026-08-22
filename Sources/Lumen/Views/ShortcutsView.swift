import SwiftUI

/// Keyboard-shortcut cheat sheet (? or ⌘/), shown as a translucent palette
/// floating over the library or the viewer. Lumen targets power users, so the
/// shortcuts should be discoverable.
struct ShortcutsPalette: View {
    var dismiss: () -> Void

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
            .init(keys: "V", action: "Toggle side previews"),
            .init(keys: "P", action: "Slideshow"),
            .init(keys: "= / – / 0", action: "Zoom in / out / reset"),
            .init(keys: "⌫", action: "Move to Trash"),
            .init(keys: "Esc", action: "Close viewer"),
        ]),
        Section(title: "App", items: [
            .init(keys: "⌘,", action: "Settings"),
            .init(keys: "? / ⌘/", action: "This shortcuts list"),
        ]),
    ]

    var body: some View {
        ZStack {
            // Dimmed backdrop; a click anywhere outside dismisses.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            palette
                .frame(width: 780)
                .frame(maxHeight: 720)
        }
        .transition(.opacity)
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 20)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top),
                                    GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 28) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.55))
                            ForEach(section.items) { item in
                                HStack(spacing: 12) {
                                    Text(item.keys)
                                        .font(.system(.body, design: .rounded).weight(.medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .background(.white.opacity(0.14),
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .frame(minWidth: 110, alignment: .leading)
                                    Text(item.action)
                                        .font(.body)
                                        .foregroundStyle(.white.opacity(0.92))
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(28)
        // Dark glass: a near-black wash over the blur so the palette reads as
        // its own surface instead of tinting whatever photo is behind it.
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.black.opacity(0.72))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.55), radius: 36, y: 14)
        .environment(\.colorScheme, .dark)
    }
}

/// Global `?` handler for the palette. SwiftUI's `onKeyPress` only fires for
/// the focused view — in the library the focus usually sits on the AppKit
/// collection/table view, so `?` looked dead there. An app-local NSEvent
/// monitor catches it from anywhere in the main window instead; text fields
/// (search, rename sheets) keep the character.
struct ShortcutsPaletteKey: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                    handle(event)
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // "?" is Shift+"/" on most layouts: match the produced character, not
        // the key code, so any layout that types "?" works.
        guard event.charactersIgnoringModifiers == "?" || event.characters == "?",
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let window = event.window, window.isKeyWindow
        else { return event }
        // Never steal the character while typing.
        if window.firstResponder is NSText { return event }
        model.showShortcuts.toggle()
        return nil
    }
}

extension View {
    func shortcutsPaletteKey() -> some View { modifier(ShortcutsPaletteKey()) }
}
