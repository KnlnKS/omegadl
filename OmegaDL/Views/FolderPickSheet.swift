import MegaKit
import SwiftUI

struct FolderPickSheet: View {
    let pick: FolderPick
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settleAnimation) private var settleAnimation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pick.root.node.name)
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
                Button(pick.count == pick.total ? "Deselect All" : "Select All") {
                    if pick.count == pick.total { pick.deselectAll() } else { pick.selectAll() }
                }
            }

            List(pick.root.children ?? [], children: \.children) { item in
                PickRow(item: item, pick: pick)
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(minHeight: 240)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(pick.count == 1 ? "Download" : "Download \(pick.count) Files") {
                    model.download([pick.root.node], from: pick.source, including: pick.files)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pick.files.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 480)
        .animation(settleAnimation, value: pick.count)
    }

    private var subtitle: String {
        pick.files.isEmpty
            ? "Nothing selected"
            : "\(pick.count) of \(pick.total) files — \(byteText(pick.bytes))"
    }
}

private struct PickRow: View {
    let item: PickNode
    let pick: FolderPick

    @Environment(\.settleAnimation) private var settleAnimation

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(settleAnimation) { pick.toggle(item) }
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(state == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Include \(item.node.name)")
            .accessibilityValue(accessibilityState)

            NodeLabel(node: item.node)
            Spacer(minLength: 8)

            Text(byteText(item.byteCount))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(settleAnimation) { pick.toggle(item) } }
    }

    private var state: FolderPick.Check { pick.check(item) }

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
