import MegaKit
import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem {
                Button("Add Link", systemImage: "plus") { model.present(.addLink) }
                    .keyboardShortcut("l", modifiers: .command)
                    .help("Add a MEGA Link")
            }
        }
        .task { await model.load() }
        .sheet(item: Binding(get: { model.sheet }, set: { if $0 == nil { model.dismissSheet() } })) { sheet in
            switch sheet {
            case .addLink: AddLinkSheet(model: model)
            case .signIn: SignInSheet(model: model)
            case .pick(let pick): FolderPickSheet(pick: pick, model: model)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.selection == .transfers {
            TransfersView(manager: model.transfers)
        } else if let account = model.account {
            switch account.state {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                ContentUnavailableView {
                    Label("Could Not Load Your Account", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                    Button("Sign Out") { model.signOut() }
                }

            case .loaded(let tree):
                if case .folder(let handle)? = model.selection, let root = tree.node(handle) {
                    BrowserView(model: model, account: account, root: root)
                        .id(handle)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Nothing Open", systemImage: "shippingbox")
            } description: {
                Text("Sign in to your account, or add a MEGA link to download it.")
            } actions: {
                Button("Sign In…") { model.present(.signIn) }
                    .buttonStyle(.borderedProminent)
                Button("Add Link…") { model.present(.addLink) }
            }
        }
    }
}
