import SwiftUI
import Photos

/// Pick an album (or create one) to file the current photo into — shown on an
/// up-swipe in organize mode.
struct AlbumPickerSheet: View {
    let albums: [PHAssetCollection]
    let onPick: (PHAssetCollection) -> Void
    let onCreate: (String) async -> PHAssetCollection?

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section("새 앨범") {
                    HStack {
                        Image(systemName: "rectangle.stack.badge.plus").foregroundStyle(.tint)
                        TextField("앨범 이름", text: $newName).submitLabel(.done)
                            .onSubmit { create() }
                        if creating { ProgressView() }
                        else {
                            Button("만들기") { create() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if !albums.isEmpty {
                    Section("기존 앨범") {
                        ForEach(albums, id: \.localIdentifier) { album in
                            Button { onPick(album); dismiss() } label: {
                                HStack {
                                    Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                                    Text(album.localizedTitle ?? "앨범").foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(album.estimatedAssetCount)").foregroundStyle(.secondary).font(.subheadline)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("앨범에 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("취소") { dismiss() } } }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !creating else { return }
        creating = true
        Task {
            if let c = await onCreate(name) { onPick(c); dismiss() }
            creating = false
        }
    }
}
