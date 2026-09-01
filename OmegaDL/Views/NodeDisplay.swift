import AppKit
import MegaKit
import SwiftUI
import UniformTypeIdentifiers

struct NodeLabel: View {
    let node: MegaNode

    var body: some View {
        Label {
            Text(node.name).lineLimit(1)
        } icon: {
            Image(nsImage: NodeIcon.image(named: node.name, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: 16, height: 16)
        }
    }
}

enum NodeIcon {
    static func image(named name: String, isDirectory: Bool = false) -> NSImage {
        guard !isDirectory else { return NSWorkspace.shared.icon(for: .folder) }
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

func byteText(_ bytes: Int) -> String {
    bytes.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
}

func rateText(_ bytesPerSecond: Double) -> String {
    "\(byteText(Int(bytesPerSecond)))/s"
}
