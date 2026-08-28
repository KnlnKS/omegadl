import UniformTypeIdentifiers
import MegaKit
import SwiftUI

struct BrowserView: View {
    @Bindable var model: AppModel
    let source: LinkSource

    @State private var selection = Set<MegaNode.ID>()

    private var breadcrumbs: [MegaNode] { model.breadcrumbs(in: source) }

    private var subtitle: String {
        guard source.status == .loaded else { return "" }
        let items = model.contents(of: source)
        return switch items.count {
        case 0: ""
        case 1: "1 item"
        default: "\(items.count) items"
        }
    }

    var body: some View {
        content
            .navigationTitle(breadcrumbs.last?.name ?? source.name)
            .navigationSubtitle(subtitle)
            .task { await source.load() }
            .toolbar { toolbar }
    }

    @ViewBuilder
    private var content: some View {
        switch source.status {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Open Link", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await source.load() } }
            }

        case .loaded:
            let items = model.contents(of: source)
            if items.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else {
                table(items)
            }
        }
    }

    private func table(_ items: [MegaNode]) -> some View {
        Table(items, selection: $selection) {
            TableColumn("Name") { node in
                NodeLabel(node: node)
            }
            TableColumn("Size") { node in
                Text(node.isDirectory ? "—" : node.size.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 76)
            TableColumn("Modified") { node in
                Text(node.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)
        }
        .contextMenu(forSelectionType: MegaNode.ID.self) { ids in
            let chosen = items.filter { ids.contains($0.id) }
            Button(chosen.count > 1 ? "Download \(chosen.count) Items" : "Download") {
                download(chosen)
            }
            .disabled(chosen.isEmpty)
        } primaryAction: { ids in
            if let node = items.first(where: { ids.contains($0.id) }) {
                open(node)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.goUp(in: source)
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(breadcrumbs.count <= 1)
            .help("Enclosing Folder")
        }
        ToolbarItem(placement: .navigation) {
            BreadcrumbBar(ancestors: breadcrumbs.dropLast()) { model.currentFolder = $0.handle }
        }
        ToolbarItem {
            Button {
                download(model.contents(of: source).filter { selection.contains($0.id) })
            } label: {
                Label("Download", systemImage: "arrow.down.to.line")
            }
            .disabled(selection.isEmpty)
            .help("Download Selection")
        }
        ToolbarItem {
            TransfersButton(manager: model.transfers)
        }
    }

    private func download(_ nodes: [MegaNode]) {
        guard !nodes.isEmpty,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        model.transfers.enqueue(nodes, from: source, into: downloads)
    }

    private func open(_ node: MegaNode) {
        guard node.isDirectory else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0)) {
            model.open(node)
        }
        selection.removeAll()
    }
}

struct BreadcrumbBar: View {
    let ancestors: [MegaNode].SubSequence
    let onSelect: (MegaNode) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ancestors) { node in
                Button {
                    onSelect(node)
                } label: {
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.accessoryBar)

                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
    }
}

struct NodeLabel: View {
    let node: MegaNode

    var body: some View {
        Label {
            Text(node.name).lineLimit(1)
        } icon: {
            Image(nsImage: NodeIcon.image(for: node))
                .resizable()
                .frame(width: 16, height: 16)
        }
    }
}

enum NodeIcon {
    static func image(for node: MegaNode) -> NSImage {
        if node.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let extensionName = (node.name as NSString).pathExtension
        let type = UTType(filenameExtension: extensionName) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
