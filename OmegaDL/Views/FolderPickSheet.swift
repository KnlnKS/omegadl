import MegaKit
import SwiftUI

struct FolderPickSheet: View {
    let pick: FolderPick
    let model: AppModel
    private var selection: FileSelection { pick.selection }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settleAnimation) private var settleAnimation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.root.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 12)
                Button(selection.count == selection.total ? "Deselect All" : "Select All") {
                    if selection.count == selection.total { pick.selection.deselectAll() } else { pick.selection.selectAll() }
                }
            }

            List(selection.root.children, children: \.outlineChildren) { item in
                PickRow(item: item, pick: pick)
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(minHeight: 240)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selection.count == 1 ? "Download" : "Download \(selection.count) Files") {
                    model.download(pick)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selection.count == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 480)
        .animation(settleAnimation, value: selection.count)
    }

    private var subtitle: String {
        selection.count == 0
            ? "Nothing selected"
            : "\(selection.count) of \(selection.total) files — \(byteText(selection.bytes))"
    }
}

private struct PickRow: View {
    let item: MegaNode
    let pick: FolderPick

    @Environment(\.settleAnimation) private var settleAnimation

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(settleAnimation) { pick.selection.toggle(item) }
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(state == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Include \(item.name)")
            .accessibilityValue(accessibilityState)

            NodeLabel(node: item)
            Spacer(minLength: 8)

            Text(byteText(item.totalSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(settleAnimation) { pick.selection.toggle(item) } }
    }

    private var state: FileSelection.Check { pick.selection.check(item) }

    private var symbol: String {
        switch state {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }

    private var accessibilityState: String {
        switch state {
        case .none: "Not included"
        case .some: "Partly included"
        case .all: "Included"
        }
    }
}

private extension MegaNode {
    var outlineChildren: [MegaNode]? { isDirectory ? children : nil }
}
