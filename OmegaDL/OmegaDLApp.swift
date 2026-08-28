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
            CommandGroup(after: .appInfo) {
                Divider()
                if model.isSignedIn {
                    Button {
                        model.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "person.crop.circle.badge.xmark")
                    }
                } else {
                    Button {
                        model.isSigningIn = true
                    } label: {
                        Label("Sign In…", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}
