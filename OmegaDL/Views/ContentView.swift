import MegaKit
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let source = model.selectedSource {
                BrowserView(model: model, source: source)
                    .id(source.id)
            } else {
                ContentUnavailableView {
                    Label("No Folder Open", systemImage: "link")
                } description: {
                    Text("Add a MEGA link to browse and download its contents.")
                } actions: {
                    Button("Add Link…") { model.isAddingLink = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: Bindable(model).isAddingLink) {
            AddLinkSheet(model: model)
        }
    }
}
