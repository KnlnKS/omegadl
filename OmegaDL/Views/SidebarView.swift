import MegaKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    @State private var isConfirmingRemoveAll = false

    var body: some View {
        List(selection: selection) {
            ForEach(model.accountItems) { item in
                row(item)
            }

            if !model.linkItems.isEmpty {
                Section("Links") {
                    ForEach(model.linkItems) { item in
                        row(item)
                            .contextMenu {
                                if let source = source(for: item) {
                                    Button(downloadTitle(for: source)) {
                                        model.downloadEverything(from: source)
                                    }
                                    .disabled(source.tree == nil)
                                    Button("Copy Link") { copy(source) }
                                    Divider()
                                    Button("Remove", role: .destructive) { model.remove(source) }
                                    Button("Remove All Links…", role: .destructive) {
                                        isConfirmingRemoveAll = true
                                    }
                                    .disabled(model.links.count < 2)
                                }
                            }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        .confirmationDialog(
            "Remove all \(model.links.count) links?",
            isPresented: $isConfirmingRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) { model.removeAllLinks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded files are not affected.")
        }
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

    private func source(for item: SidebarItem) -> Source? {
        model.sources.first { $0.id == item.sourceID }
    }

    private func downloadTitle(for source: Source) -> String {
        source.link?.kind == .file ? "Download" : "Download Folder"
    }

    private func copy(_ source: Source) {
        guard let link = source.link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
    }
}
