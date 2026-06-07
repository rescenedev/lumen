import SwiftUI

/// Preferences window (⌘,).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            storage.tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 420, height: 240)
    }

    private var general: some View {
        Form {
            Toggle("Confirm before moving to Trash", isOn: $model.confirmBeforeDelete)
            VStack(alignment: .leading) {
                Text("Slideshow interval: \(model.slideshowInterval, specifier: "%.1f")s")
                Slider(value: $model.slideshowInterval, in: 1...10, step: 0.5)
            }
            Picker("Default sort", selection: $model.sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        .padding(20)
    }

    private var storage: some View {
        Form {
            LabeledContent("Photos loaded", value: "\(model.totalCount)")
            LabeledContent("Geotagged", value: "\(model.exif.values.lazy.filter { $0.hasGPS }.count)")

            Section("Duplicates") {
                HStack {
                    Button("Scan for Duplicates") { model.findDuplicates() }
                        .disabled(model.isFindingDuplicates || model.totalCount == 0)
                    if model.isFindingDuplicates {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text("\(model.duplicatePaths.count) found").foregroundStyle(.secondary)
                }
                Text("Reads file contents — can be slow on network volumes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button("Clear Thumbnail Cache") {
                ThumbnailCache.shared.clear()
                ThumbnailCache.shared.clearDisk()
            }
        }
        .padding(20)
    }
}
