import Foundation
import MegaKit
import Observation

@Observable
final class AppModel {
    let transfers = TransferManager()
    private(set) var sources: [LinkSource] = []
    var selectedSourceID: LinkSource.ID?
    var currentFolder: String?
    var isAddingLink = false

    private static let storageKey = "SavedLinks"

    init() {
        sources = (UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? [])
            .compactMap(MegaLink.init)
            .compactMap { try? LinkSource(link: $0) }
        selectedSourceID = sources.first?.id
    }

    var selectedSource: LinkSource? {
        sources.first { $0.id == selectedSourceID }
    }

    @discardableResult
    func addLink(_ text: String) -> Bool {
        guard let link = MegaLink(text), let source = try? LinkSource(link: link) else { return false }
        if let existing = sources.first(where: { $0.link == link }) {
            selectedSourceID = existing.id
            return true
        }
        sources.append(source)
        selectedSourceID = source.id
        persist()
        return true
    }

    func remove(_ source: LinkSource) {
        sources.removeAll { $0.id == source.id }
        if selectedSourceID == source.id {
            selectedSourceID = sources.first?.id
            currentFolder = nil
        }
        persist()
    }

    func breadcrumbs(in source: LinkSource) -> [MegaNode] {
        guard let tree = source.tree else { return [] }
        guard let folder = currentFolder, tree.node(folder) != nil else {
            return tree.roots.prefix(1).map { $0 }
        }
        return tree.path(to: folder)
    }

    func contents(of source: LinkSource) -> [MegaNode] {
        guard let tree = source.tree else { return [] }
        let folder = currentFolder ?? tree.roots.first?.handle
        guard let folder else { return tree.roots }
        return tree.children(of: folder)
    }

    func open(_ node: MegaNode) {
        guard node.isDirectory else { return }
        currentFolder = node.handle
    }

    func goUp(in source: LinkSource) {
        guard let tree = source.tree, let folder = currentFolder else { return }
        currentFolder = tree.node(folder)?.parentHandle.flatMap { tree.node($0) }?.handle
    }

    private func persist() {
        UserDefaults.standard.set(sources.map(\.link.url.absoluteString), forKey: Self.storageKey)
    }
}
