import AppKit
import MegaKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Bindable var model: AppModel
    let source: Source

    @State private var selection = Set<MegaNode.ID>()
    @State private var isDropTargeted = false
    @Environment(\.fluidAnimation) private var fluidAnimation
    @Environment(\.settleAnimation) private var settleAnimation

    private var uploadTarget: String? { model.uploadTarget(in: source) }

    var body: some View {
        content
            .navigationTitle(model.title(for: source))
            .task { await source.load() }
            .toolbar { toolbar }
            .background {
                Group {
                    Button("Open Selection") { openSelection() }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                    Button("Download Selection") { download(selectedNodes) }
                        .keyboardShortcut("d", modifiers: .command)
                        .disabled(selection.isEmpty)
                    Button("Upload") { chooseUploads() }
                        .keyboardShortcut("u", modifiers: .command)
                        .disabled(uploadTarget == nil)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
            .dropDestination(for: URL.self) { urls, _ in accept(urls) } isTargeted: { targeted in
                withAnimation(settleAnimation) { isDropTargeted = targeted }
            }
            .overlay {
                if isDropTargeted, uploadTarget != nil {
                    DropIndicator(folder: model.title(for: source))
                }
            }
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
                emptyFolder
            } else {
                table(items)
            }
        }
    }

    @ViewBuilder
    private var emptyFolder: some View {
        let view = ContentUnavailableView("Empty Folder", systemImage: "folder")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)

        if uploadTarget != nil {
            view.contextMenu { uploadButton }
        } else {
            view
        }
    }

    private func table(_ items: [MegaNode]) -> some View {
        Table(items, selection: $selection) {
            TableColumn("Name") { node in
                NodeLabel(node: node)
                    .accessibilityLabel(
                        node.isDirectory
                            ? "\(node.name), folder"
                            : "\(node.name), \(node.size.formatted(.byteCount(style: .file)))"
                    )
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
            if !chosen.isEmpty {
                Button(chosen.count > 1 ? "Download \(chosen.count) Items" : "Download") {
                    download(chosen)
                }
            }
            if uploadTarget != nil {
                if !chosen.isEmpty { Divider() }
                uploadButton
            }
        } primaryAction: { ids in
            if let node = items.first(where: { ids.contains($0.id) }) {
                open(node)
            }
        }
    }

    private var uploadButton: some View {
        Button("Upload…") { chooseUploads() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.goUp(in: source)
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.canGoUp)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Enclosing Folder")
        }
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await source.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(source.isRefreshing || source.status != .loaded)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh")
        }
    }

    private var selectedNodes: [MegaNode] {
        model.contents(of: source).filter { selection.contains($0.id) }
    }

    private func chooseUploads() {
        guard let parent = uploadTarget else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(model.title(for: source))."

        guard panel.runModal() == .OK else { return }
        model.transfers.upload(panel.urls, to: source, parent: parent)
    }

    private func accept(_ urls: [URL]) -> Bool {
        guard let parent = uploadTarget else { return false }
        model.transfers.upload(urls, to: source, parent: parent)
        return true
    }

    private func download(_ nodes: [MegaNode]) {
        model.download(nodes, from: source)
    }

    private func openSelection() {
        if let node = selectedNodes.first, node.isDirectory {
            open(node)
        }
    }

    private func open(_ node: MegaNode) {
        guard node.isDirectory else { return }
        withAnimation(fluidAnimation) {
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
