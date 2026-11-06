import MegaKit
import SwiftUI

struct SidebarView: View {
    let model: AppModel

    var body: some View {
        List(selection: selection) {
            if let roots = model.account?.tree?.roots, !roots.isEmpty {
                ForEach(roots) { root in
                    label(root.name, symbol: symbol(for: root.kind))
                        .tag(SidebarSelection.folder(root.id))
                }
                Divider()
                    .selectionDisabled()
            }
            transfersRow
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
    }

    private var selection: Binding<SidebarSelection?> {
        Binding(get: { model.selection }, set: { if let selection = $0 { model.selection = selection } })
    }

    private var transfersRow: some View {
        let manager = model.transfers
        return HStack {
            label("Transfers", symbol: "arrow.up.arrow.down")
            Spacer(minLength: 0)
            if manager.list.activeCount > 0 {
                TransferRing(fraction: manager.aggregateFraction)
            }
        }
        .tag(SidebarSelection.transfers)
        .accessibilityValue(
            manager.list.activeCount == 0
                ? ""
                : "\(manager.list.activeCount) active, \(Int(manager.aggregateFraction * 100)) percent"
        )
    }

    private func label(_ name: String, symbol: String) -> some View {
        Label(name, systemImage: symbol)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func symbol(for kind: MegaNode.Kind) -> String {
        switch kind {
        case .root: "cloud"
        case .inbox: "tray"
        case .rubbish: "trash"
        case .folder: "folder"
        case .file: "doc"
        }
    }
}
