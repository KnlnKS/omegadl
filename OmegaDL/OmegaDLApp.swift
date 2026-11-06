import AppKit
import SwiftUI

@main
enum Launcher {
    /// A unit test host runs a bare application, so tests never touch the Keychain or saved transfers.
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            OmegaDLApp.main()
        } else {
            NSApplication.shared.run()
        }
    }
}

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
            CommandGroup(after: .sidebar) {
                Button("Transfers") { model.selection = .transfers }
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }
            CommandGroup(after: .appInfo) {
                Divider()
                if model.account != nil {
                    Button("Sign Out", systemImage: "person.crop.circle.badge.xmark") { model.signOut() }
                } else {
                    Button("Sign In", systemImage: "person.crop.circle.badge.plus") { model.present(.signIn) }
                        .disabled(model.sheet != nil)
                }
            }
        }

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
