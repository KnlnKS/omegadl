import SwiftUI

@main
struct OmegaDLApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 440)
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandMenu("Account") {
                if model.isSignedIn {
                    Button("Sign Out") { model.signOut() }
                } else {
                    Button("Sign In…") { model.isSigningIn = true }
                }
                Divider()
                Button("Add Link…") { model.isAddingLink = true }
                    .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}
