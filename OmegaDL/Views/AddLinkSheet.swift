import MegaKit
import SwiftUI

struct AddLinkSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isInvalid = false
    @Environment(\.fluidAnimation) private var fluidAnimation
    @FocusState private var isFocused: Bool

    private var isValid: Bool { MegaLink(text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a MEGA Link")
                    .font(.headline)
                Text("Paste a folder or file link. Its key stays on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("https://mega.nz/folder/…#…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($isFocused)
                .onSubmit(add)
                .onChange(of: text) { isInvalid = false }

            Text(isInvalid ? "That does not look like a MEGA link." : " ")
                .font(.caption)
                .foregroundStyle(.red)
                .opacity(isInvalid ? 1 : 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFocused = true }
        .animation(fluidAnimation, value: isInvalid)
    }

    private func add() {
        guard isValid, model.addLink(text) else {
            isInvalid = true
            return
        }
        dismiss()
    }
}
