import MegaKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if model.isShowingTransfers {
                TransfersView(manager: model.transfers)
            } else if let source = model.selectedSource {
                BrowserView(model: model, source: source)
                    .id(model.selectedItemID)
            } else {
                ContentUnavailableView {
                    Label("Nothing Open", systemImage: "shippingbox")
                } description: {
                    Text("Sign in to your account, or add a MEGA link to download it.")
                } actions: {
                    Button("Sign In…") { model.isSigningIn = true }
                        .buttonStyle(.borderedProminent)
                    Button("Add Link…") { model.isAddingLink = true }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.isAddingLink = true
                } label: {
                    Label("Add Link", systemImage: "plus")
                }
                .keyboardShortcut("l", modifiers: .command)
                .help("Add a MEGA Link")
            }
            ToolbarItem {
                TransfersButton(manager: model.transfers)
            }
        }
        .task { await model.loadAllSources() }
        .sheet(isPresented: $model.isAddingLink) {
            AddLinkSheet(model: model)
        }
        .sheet(isPresented: $model.isSigningIn) {
            SignInSheet(model: model)
        }
        .sheet(item: $model.currentPick) { pick in
            FolderPickSheet(pick: pick, model: model)
        }
    }
}
