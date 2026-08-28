import MegaKit
import SwiftUI

struct AddLinkSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fluidAnimation) private var fluidAnimation
    @State private var text = ""
    @State private var isInvalid = false
    @State private var found: [MegaLink] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add MEGA Links")
                    .font(.headline)
                Text("Paste one link or many. Their keys stay on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("https://mega.nz/folder/…#…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...10)
                .font(.system(.body, design: .monospaced))
                .focused($isFocused)
                .onChange(of: text) {
                    isInvalid = false
                    found = MegaLink.links(in: text)
                }

            status

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle, action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(found.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { isFocused = true }
        .animation(fluidAnimation, value: found.count)
        .animation(fluidAnimation, value: isInvalid)
    }

    @ViewBuilder
    private var status: some View {
        if isInvalid {
            Label("No MEGA links found in that text.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if found.count > 1 {
            Label("\(found.count) links found", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(" ").font(.caption)
        }
    }

    private var addTitle: String {
        found.count > 1 ? "Add \(found.count) Links" : "Add"
    }

    private func add() {
        guard model.addLinks(text) > 0 else {
            isInvalid = true
            return
        }
        dismiss()
    }
}
