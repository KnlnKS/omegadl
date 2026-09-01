import MegaKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: selection) {
            ForEach(model.accountItems) { item in
                row(item)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
    }

    private var selection: Binding<SidebarItem.ID?> {
        Binding(get: { model.selectedItemID }, set: { model.select($0) })
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.name, systemImage: item.symbol)
            .lineLimit(1)
            .truncationMode(.middle)
            .tag(item.id)
    }
}
