import MegaKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: selection) {
            ForEach(model.accountItems) { item in
                row(item)
            }
            if !model.accountItems.isEmpty {
                Divider()
                    .selectionDisabled()
            }
            transfersRow
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
    }

    private var selection: Binding<SidebarItem.ID?> {
        Binding(get: { model.selectedItemID }, set: { model.select($0) })
    }

    private var transfersRow: some View {
        let manager = model.transfers
        return HStack {
            label(.transfers)
            Spacer(minLength: 0)
            if manager.activeCount > 0 {
                TransferRing(fraction: manager.aggregateFraction)
            }
        }
        .tag(SidebarItem.ID.transfers)
        .accessibilityValue(
            manager.activeCount == 0
                ? ""
                : "\(manager.activeCount) active, \(Int(manager.aggregateFraction * 100)) percent"
        )
    }

    private func row(_ item: SidebarItem) -> some View {
        label(item).tag(item.id)
    }

    private func label(_ item: SidebarItem) -> some View {
        Label(item.name, systemImage: item.symbol)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
