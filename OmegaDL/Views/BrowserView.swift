import UniformTypeIdentifiers
import MegaKit
import SwiftUI

struct BrowserView: View {
    @Bindable var model: AppModel
    let source: LinkSource

    @State private var selection = Set<MegaNode.ID>()

    private var breadcrumbs: [MegaNode] { model.breadcrumbs(in: source) }

    var body: some View {
        content
            .navigationTitle(breadcrumbs.last?.name ?? source.name)
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
            .width(min: 70, ideal: 90)
            TableColumn("Modified") { node in
                Text(node.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
        }
        .contextMenu(forSelectionType: MegaNode.ID.self) { _ in
            EmptyView()
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
            BreadcrumbBar(nodes: breadcrumbs) { model.currentFolder = $0.handle }
        }
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
    let nodes: [MegaNode]
    let onSelect: (MegaNode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                }
                Button {
                    onSelect(node)
                } label: {
                    Text(node.name)
                        .lineLimit(1)
                        .fontWeight(index == nodes.count - 1 ? .semibold : .regular)
                }
                .buttonStyle(.accessoryBar)
                .disabled(index == nodes.count - 1)
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
