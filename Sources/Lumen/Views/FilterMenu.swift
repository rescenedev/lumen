import SwiftUI

/// Toolbar filter control: a menu of attribute filters with a badge when active.
struct FilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return Perf.body("FilterMenu") { Menu {
            Toggle("Favorites Only", isOn: $model.filter.favoritesOnly)
                .onAppear { model.ensureExifIndex() }   // populate camera/GPS data on open
            Toggle("Hide Rejected", isOn: $model.filter.hideRejected)
            Toggle("Has Location", isOn: $model.filter.gpsOnly)

            Picker("Minimum Rating", selection: $model.filter.minRating) {
                Text("Any").tag(0)
                ForEach(1...5, id: \.self) { n in
                    Text(String(repeating: "★", count: n)).tag(n)
                }
            }

            Menu("Label") {
                Button("Any") { model.filter.label = nil }
                ForEach(ColorLabel.allCases.filter { $0 != .none }) { label in
                    Button(label.title) { model.filter.label = label }
                }
            }

            if !model.availableFileTypes.isEmpty {
                Menu("File Type") {
                    Button("Any") { model.filter.fileType = nil }
                    ForEach(model.availableFileTypes, id: \.self) { type in
                        Button(type.uppercased()) { model.filter.fileType = type }
                    }
                }
            }

            if !model.availableCameras.isEmpty {
                Menu("Camera") {
                    Button("Any") { model.filter.camera = nil }
                    ForEach(model.availableCameras, id: \.self) { camera in
                        Button(camera) { model.filter.camera = camera }
                    }
                }
            }

            if model.filter.isActive {
                Divider()
                Button("Clear Filters") { model.filter = .none }
            }
        } label: {
            Label("Filter", systemImage: model.filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .help(model.filter.isActive ? "Filters active: \(model.filter.chips.joined(separator: ", "))" : "Filter photos")
        }
    }
}
