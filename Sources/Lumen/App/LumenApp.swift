import SwiftUI

struct LumenApp: App {
    @NSApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lumen") { model.showAbout = true }
                Button("Check for Updates…") { model.checkForUpdates(force: true) }
            }

            CommandGroup(after: .sidebar) {
                Picker("Show", selection: $model.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Group by Month", isOn: $model.groupByMonth)
            }

            // File menu additions
            CommandGroup(after: .newItem) {
                Button("Refresh Photos Library") { model.refreshPhotosLibrary() }
                    .keyboardShortcut("r", modifiers: .command)

                Button("Add to Library…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Clear Library") { model.clearLibrary() }
                    .disabled(model.totalCount == 0)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Select All") { model.selectAll(model.visiblePhotos) }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(model.totalCount == 0)
                Button("Move to Trash") { model.requestDeletion(model.deletionTargets) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.deletionTargets.isEmpty)
                Divider()
                Button("Organize History…") { model.showHistory = true }
                    .keyboardShortcut("y", modifiers: .command)
            }

            // View menu additions
            CommandGroup(after: .toolbar) {
                Picker("View As", selection: $model.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
                Button("As Grid") { model.viewMode = .grid }
                    .keyboardShortcut("1", modifiers: .command)
                Button("As List") { model.viewMode = .list }
                    .keyboardShortcut("2", modifiers: .command)
                Button("As Map") { model.viewMode = .map }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Larger Thumbnails") {
                    model.thumbnailSize = min(320, model.thumbnailSize + 30)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Thumbnails") {
                    model.thumbnailSize = max(90, model.thumbnailSize - 30)
                }
                .keyboardShortcut("-", modifiers: .command)
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
                Button("Lumen Help") {
                    if let url = URL(string: "https://rescenedev.github.io/lumen") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
