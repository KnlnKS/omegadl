import AppKit
import MegaKit
import SwiftUI

struct BrowserView: View {
    let model: AppModel
    let account: Source
    let root: MegaNode

    @State private var folderHandle: NodeHandle?
    @State private var selection = Set<MegaNode.ID>()
    @State private var isDropTargeted = false
    @State private var pendingDeletion: [MegaNode] = []
    @State private var actionError: String?
    @State private var isWorking = false
    @Environment(\.fluidAnimation) private var fluidAnimation
    @Environment(\.settleAnimation) private var settleAnimation

    /// The open folder, or the root once that folder has gone from it.
    private var folder: MegaNode {
        guard let folderHandle, let node = root.tree.node(folderHandle), root.contains(node) else { return root }
        return node
    }

    private var canUpload: Bool { root.kind == .root }
    private var rubbish: MegaNode? { root.tree.roots.first { $0.kind == .rubbish } }

    var body: some View {
        let folder = folder
        let items = folder.children
        content(items)
            .navigationTitle(folder.name)
            .toolbar { toolbar(canGoUp: folder.id != root.id) }
            .background {
                Group {
                    Button("Open Selection") { openSelection() }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                    Button("Download Selection") { download(selectedNodes) }
                        .keyboardShortcut("d", modifiers: .command)
                        .disabled(!items.contains { selection.contains($0.id) })
                    Button("Upload") { chooseUploads() }
                        .keyboardShortcut("u", modifiers: .command)
                        .disabled(!canUpload)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
            .dropDestination(for: URL.self) { urls, _ in accept(urls) } isTargeted: { targeted in
                withAnimation(settleAnimation) { isDropTargeted = targeted }
            }
            .overlay {
                if isDropTargeted, canUpload {
                    DropIndicator(folder: folder.name)
                }
            }
            .confirmationDialog(
                deletionPrompt,
                isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete(pendingDeletion) }
                Button("Cancel", role: .cancel) { pendingDeletion = [] }
            } message: {
                Text("This cannot be undone.")
            }
            .alert(
                "Could Not Complete That",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
    }

    @ViewBuilder
    private func content(_ items: [MegaNode]) -> some View {
        if items.isEmpty {
            emptyFolder
        } else {
            table(items)
        }
    }

    @ViewBuilder
    private var emptyFolder: some View {
        let view = ContentUnavailableView("Empty Folder", systemImage: "folder")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)

        if canUpload {
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
                            : "\(node.name), \(byteText(node.size))"
                    )
            }
            TableColumn("Size") { node in
                Text(node.isDirectory ? "—" : byteText(node.size))
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
            if canUpload {
                uploadButton
            }
            if root.kind == .rubbish, !chosen.isEmpty {
                Divider()
                Group {
                    if let target = restoreLabel(for: chosen) {
                        Button("Put Back") { perform { try await account.session.putBack(chosen) } }
                            .help("Restore to \(target)")
                    }
                    Button("Delete Immediately…", role: .destructive) { pendingDeletion = chosen }
                }
                .disabled(isWorking)
            } else if canUpload, !chosen.isEmpty, let rubbish {
                Divider()
                Button("Move to Rubbish Bin") {
                    perform { try await account.session.move(chosen, to: rubbish.id, recordingOrigin: true) }
                }
                .disabled(isWorking)
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
    private func toolbar(canGoUp: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { withAnimation(fluidAnimation) { folderHandle = folder.parent?.id } }
                .disabled(!canGoUp)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Enclosing Folder")
        }
        ToolbarItem(placement: .navigation) {
            Button("Refresh", systemImage: "arrow.clockwise") { perform {} }
                .disabled(isWorking)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh")
        }
    }

    private var selectedNodes: [MegaNode] {
        folder.children.filter { selection.contains($0.id) }
    }

    private func chooseUploads() {
        guard canUpload else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(folder.name)."

        guard panel.runModal() == .OK else { return }
        _ = accept(panel.urls)
    }

    private func accept(_ urls: [URL]) -> Bool {
        guard canUpload else { return false }
        model.transfers.upload(urls, to: account, parent: folder.id)
        return true
    }

    private func download(_ nodes: [MegaNode]) {
        model.download(nodes, from: account)
    }

    private var deletionPrompt: String {
        pendingDeletion.count == 1
            ? "Delete “\(pendingDeletion[0].name)” permanently?"
            : "Delete \(pendingDeletion.count) items permanently?"
    }

    private func restoreLabel(for nodes: [MegaNode]) -> String? {
        let targets = nodes.compactMap(\.restoreTarget)
        guard targets.count == nodes.count else { return nil }
        return Set(targets.map(\.id)).count == 1 ? targets[0].name : "their original folders"
    }

    private func delete(_ nodes: [MegaNode]) {
        pendingDeletion = []
        perform { try await account.session.delete(nodes) }
    }

    /// Runs `change`, then refreshes, reporting the first failure.
    private func perform(_ change: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            var failure: (any Error)?
            do { try await change() } catch { failure = error }
            do { try await account.refresh() } catch { failure = failure ?? error }
            isWorking = false
            actionError = failure?.localizedDescription
        }
    }

    private func openSelection() {
        if let node = selectedNodes.first { open(node) }
    }

    private func open(_ node: MegaNode) {
        guard node.isDirectory else { return }
        withAnimation(fluidAnimation) {
            folderHandle = node.id
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
