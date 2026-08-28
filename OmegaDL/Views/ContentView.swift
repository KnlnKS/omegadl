import MegaKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let source = model.selectedSource {
                BrowserView(model: model, source: source)
                    .id(model.selectedItemID)
            } else {
                ContentUnavailableView {
                    Label("Nothing Open", systemImage: "shippingbox")
                } description: {
                    Text("Sign in to your account, or add a MEGA link to browse and download it.")
                } actions: {
                    Button("Sign In…") { model.isSigningIn = true }
                        .buttonStyle(.borderedProminent)
                    Button("Add Link…") { model.isAddingLink = true }
                }
            }
        }
        .task { await model.loadAllSources() }
        .sheet(isPresented: $model.isAddingLink) {
            AddLinkSheet(model: model)
        }
        .sheet(isPresented: $model.isSigningIn) {
            SignInSheet(model: model)
        }
    }
}
