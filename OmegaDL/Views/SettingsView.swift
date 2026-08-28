import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(Preferences.downloadPathKey) private var downloadPath = ""
    @AppStorage(Preferences.simultaneousTransfersKey)
    private var simultaneousTransfers = Preferences.simultaneousTransfersDefault
    @AppStorage(Preferences.connectionsPerTransferKey)
    private var connectionsPerTransfer = Preferences.connectionsPerTransferDefault

    private var destination: URL {
        downloadPath.isEmpty ? Preferences.systemDownloads : URL(filePath: downloadPath)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Save downloads to") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: destination.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(destination.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Change…", action: chooseDestination)
                        if !downloadPath.isEmpty {
                            Button("Reset") { downloadPath = "" }
                        }
                    }
                }
            }

            Section {
                Picker("Simultaneous transfers", selection: $simultaneousTransfers) {
                    ForEach(1...6, id: \.self) { Text($0.formatted()).tag($0) }
                }
                Picker("Connections per transfer", selection: $connectionsPerTransfer) {
                    ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { Text($0.formatted()).tag($0) }
                }
            } footer: {
                Text("More connections speed up large files, with diminishing returns past eight. MEGA may throttle very high counts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.prompt = "Choose"
        panel.message = "Choose where OmegaDL saves downloads."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadPath = url.path
    }
}
