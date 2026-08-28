import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Cloud Drive", systemImage: "cloud")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            ContentUnavailableView("Nothing Selected", systemImage: "folder")
        }
    }
}
