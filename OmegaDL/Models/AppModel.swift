import Foundation
import MegaKit
import Observation

@Observable
final class AppModel {
    let transfers = TransferManager()

    private(set) var links: [Source] = []
    private(set) var account: Source?

    var selectedSourceID: Source.ID?
    var currentFolder: String?
    var isAddingLink = false
    var isSigningIn = false

    private static let linksKey = "SavedLinks"
    private static let accountKey = "SignedInEmail"

    init() {
        links = (UserDefaults.standard.stringArray(forKey: Self.linksKey) ?? [])
            .compactMap(MegaLink.init)
            .compactMap { try? Source(link: $0) }

        if let email = UserDefaults.standard.string(forKey: Self.accountKey),
           let stored = Keychain.session(email: email) {
            account = Source(account: stored)
        }
        selectedSourceID = account?.id ?? links.first?.id
    }

    var sources: [Source] {
        (account.map { [$0] } ?? []) + links
    }

    var selectedSource: Source? {
        sources.first { $0.id == selectedSourceID }
    }

    @discardableResult
    func addLink(_ text: String) -> Bool {
        guard let link = MegaLink(text), let source = try? Source(link: link) else { return false }
        if let existing = links.first(where: { $0.link == link }) {
            selectedSourceID = existing.id
            return true
        }
        links.append(source)
        selectedSourceID = source.id
        persistLinks()
        return true
    }

    func remove(_ source: Source) {
        links.removeAll { $0.id == source.id }
        if selectedSourceID == source.id {
            selectedSourceID = sources.first?.id
            currentFolder = nil
        }
        persistLinks()
    }

    func signIn(with session: AccountSession) throws {
        try Keychain.save(session)
        UserDefaults.standard.set(session.email, forKey: Self.accountKey)
        account = Source(account: session)
        selectedSourceID = account?.id
        currentFolder = nil
    }

    func signOut() {
        if case .account(let session)? = account?.kind {
            Keychain.remove(email: session.email)
        }
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        account = nil
        selectedSourceID = links.first?.id
        currentFolder = nil
    }

    func breadcrumbs(in source: Source) -> [MegaNode] {
        guard let tree = source.tree else { return [] }
        if let folder = currentFolder, tree.node(folder) != nil {
            return tree.path(to: folder)
        }
        return tree.roots.count == 1 ? Array(tree.roots.prefix(1)) : []
    }

    func contents(of source: Source) -> [MegaNode] {
        guard let tree = source.tree else { return [] }
        if let folder = currentFolder, tree.node(folder) != nil {
            return tree.children(of: folder)
        }
        return tree.roots.count == 1 ? tree.children(of: tree.roots[0].handle) : tree.roots
    }

    func open(_ node: MegaNode) {
        guard node.isDirectory else { return }
        currentFolder = node.handle
    }

    func goUp(in source: Source) {
        guard let tree = source.tree, let folder = currentFolder else { return }
        let parent = tree.node(folder)?.parentHandle.flatMap { tree.node($0) }
        currentFolder = tree.roots.count == 1 && parent?.handle == tree.roots[0].handle ? nil : parent?.handle
    }

    private func persistLinks() {
        UserDefaults.standard.set(links.compactMap { $0.link?.url.absoluteString }, forKey: Self.linksKey)
    }
}
