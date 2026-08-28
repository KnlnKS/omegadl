import UniformTypeIdentifiers
import MegaKit
import SwiftUI

struct BrowserView: View {
    @Bindable var model: AppModel
    let source: Source

    @State private var selection = Set<MegaNode.ID>()
    @State private var isDropTargeted = false

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
            .dropDestination(for: URL.self) { urls, _ in accept(urls) } isTargeted: { targeted in
                withAnimation(.spring(duration: 0.25, bounce: 0)) { isDropTargeted = targeted }
            }
            .overlay {
                if isDropTargeted, model.uploadTarget(in: source) != nil {
                    DropIndicator(folder: breadcrumbs.last?.name ?? source.name)
                }
            }
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
            .disabled(model.currentFolder == nil)
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
            Button {
                chooseUploads()
            } label: {
                Label("Upload", systemImage: "arrow.up.to.line")
            }
            .disabled(model.uploadTarget(in: source) == nil)
            .help(source.allowsUpload ? "Upload to This Folder" : "Sign in to upload")
        }
        ToolbarItem {
            TransfersButton(manager: model.transfers)
        }
    }

    private func chooseUploads() {
        guard let parent = model.uploadTarget(in: source) else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(breadcrumbs.last?.name ?? source.name)."

        guard panel.runModal() == .OK else { return }
        model.transfers.upload(panel.urls, to: source, parent: parent)
    }

    private func accept(_ urls: [URL]) -> Bool {
        guard let parent = model.uploadTarget(in: source) else { return false }
        model.transfers.upload(urls, to: source, parent: parent)
        return true
    }

    private func download(_ nodes: [MegaNode]) {
        guard !nodes.isEmpty,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        model.transfers.download(nodes, from: source, into: downloads)
    }

    private func open(_ node: MegaNode) {
        guard node.isDirectory else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0)) {
            model.open(node)
        }
        selection.removeAll()
    }
}

struct DropIndicator: View {
    let folder: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .background(RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.08)))

            Label("Upload to \(folder)", systemImage: "arrow.up.circle")
                .font(.title3)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: .capsule)
        }
        .padding(10)
        .allowsHitTesting(false)
        .transition(.opacity)
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
        image(named: node.name, isDirectory: node.isDirectory)
    }

    static func image(named name: String, isDirectory: Bool = false) -> NSImage {
        guard !isDirectory else { return NSWorkspace.shared.icon(for: .folder) }
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
