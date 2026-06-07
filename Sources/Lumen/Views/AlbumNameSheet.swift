import SwiftUI

/// A small sheet for naming an album (create or rename) with the text field
/// auto-focused — unlike `.alert`, which focuses a button by default.
struct AlbumNameSheet: View {
    let title: String
    let confirmLabel: String
    var placeholder: String = "Album name"
    @Binding var text: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }

    private func confirm() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onConfirm()
        dismiss()
    }
}
