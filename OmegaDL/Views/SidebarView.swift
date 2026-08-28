import MegaKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedSourceID) {
            Section("Links") {
                ForEach(model.sources) { source in
                    Label(source.name, systemImage: symbol(for: source))
                        .lineLimit(1)
                        .tag(source.id)
                        .contextMenu {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(source.link.url.absoluteString, forType: .string)
                            }
                            Button("Remove", role: .destructive) { model.remove(source) }
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.isAddingLink = true
            } label: {
                Label("Add Link", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.accessoryBar)
            .padding(8)
        }
        .onChange(of: model.selectedSourceID) {
            model.currentFolder = nil
        }
    }

    private func symbol(for source: LinkSource) -> String {
        switch source.status {
        case .failed: "exclamationmark.triangle"
        case .loading: "arrow.trianglehead.2.clockwise"
        default: source.link.kind == .folder ? "folder" : "doc"
        }
    }
}
