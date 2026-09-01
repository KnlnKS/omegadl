import AppKit
import SwiftUI

@main
struct OmegaDLApp: App {
    @NSApplicationDelegateAdaptor(MenuBarTrimmer.self) private var menuBar
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
                        Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        }

        Window("Transfers", id: "transfers") {
            TransfersView(manager: model.transfers)
                .frame(minWidth: 420, minHeight: 240)
        }
        .defaultSize(width: 480, height: 360)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("t", modifiers: [.command, .option])

        Settings {
            SettingsView()
        }
    }
}

final class MenuBarTrimmer: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let markers: Set<Selector> = [
            #selector(NSText.paste(_:)),
            #selector(NSWindow.performClose(_:)),
        ]
        for item in NSApp.mainMenu?.items ?? [] {
            guard let submenu = item.submenu else { continue }
            if submenu.items.contains(where: { $0.action.map(markers.contains) ?? false }) {
                item.isHidden = true
            }
        }
    }
}
