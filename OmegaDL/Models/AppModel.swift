import Foundation
import MegaKit
import Observation

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let sourceID: Source.ID
    let rootHandle: String?
    let name: String
    let symbol: String
}

@Observable
final class AppModel {
    let transfers = TransferManager()

    private(set) var links: [Source] = []
    private(set) var account: Source?

    var selectedItemID: SidebarItem.ID?
    var currentFolder: String?
    var isAddingLink = false
    var isSigningIn = false

    private static let linksKey = "SavedLinks"
    private static let accountKey = "SignedInEmail"

    init() {
        links = (UserDefaults.standard.stringArray(forKey: Self.linksKey) ?? [])
            .compactMap(MegaLink.init)
            .compactMap { try? Source(link: $0) }
    }

    private func restoreAccount() async {
        guard account == nil,
              let email = UserDefaults.standard.string(forKey: Self.accountKey),
              let stored = await Keychain.storedSession(email: email)
        else { return }
        account = Source(account: stored)
    }

    var sources: [Source] {
        (account.map { [$0] } ?? []) + links
    }

    var isSignedIn: Bool { account != nil }

    var accountItems: [SidebarItem] {
        guard let account, let tree = account.tree else { return [] }
        return tree.roots.sorted { $0.kind.rawValue < $1.kind.rawValue }.map { root in
            SidebarItem(
                id: "\(account.id)/\(root.handle)",
                sourceID: account.id,
                rootHandle: root.handle,
                name: root.name,
                symbol: symbol(for: root.kind)
            )
        }
    }

    var linkItems: [SidebarItem] {
        links.map { source in
            SidebarItem(
                id: source.id.uuidString,
                sourceID: source.id,
                rootHandle: nil,
                name: source.name,
                symbol: source.symbol
            )
        }
    }

    private func symbol(for kind: MegaNode.Kind) -> String {
        switch kind {
        case .root: "cloud"
        case .inbox: "tray"
        case .rubbish: "trash"
        case .folder: "folder"
        case .file: "doc"
        }
    }

    var selectedItem: SidebarItem? {
        (accountItems + linkItems).first { $0.id == selectedItemID }
    }

    var selectedSource: Source? {
        guard let sourceID = selectedItem?.sourceID else { return nil }
        return sources.first { $0.id == sourceID }
    }

    var rootHandle: String? {
        guard let item = selectedItem else { return nil }
        return item.rootHandle ?? selectedSource?.tree?.roots.first?.handle
    }

    var folder: String? {
        currentFolder ?? rootHandle
    }

    var canGoUp: Bool {
        guard let folder, let rootHandle else { return false }
        return folder != rootHandle
    }

    func loadAllSources() async {
        await restoreAccount()
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await source.load() }
            }
        }
        if selectedItemID == nil {
            selectedItemID = (accountItems + linkItems).first?.id
        }
    }

    @discardableResult
    func addLinks(_ text: String) -> Int {
        let parsed = MegaLink.links(in: text)
        guard !parsed.isEmpty else { return 0 }

        var firstID: SidebarItem.ID?
        for link in parsed {
            if let existing = links.first(where: { $0.link == link }) {
                firstID = firstID ?? existing.id.uuidString
                continue
            }
            guard let source = try? Source(link: link) else { continue }
            links.append(source)
            firstID = firstID ?? source.id.uuidString
            Task { await source.load() }
        }

        persistLinks()
        if let firstID { select(firstID) }
        return parsed.count
    }

    func remove(_ source: Source) {
        links.removeAll { $0.id == source.id }
        if selectedItem?.sourceID == source.id {
            select((accountItems + linkItems).first?.id)
        }
        persistLinks()
    }

    func removeAllLinks() {
        links.removeAll()
        persistLinks()
        if selectedItem == nil || linkItems.isEmpty {
            select((accountItems + linkItems).first?.id)
        }
    }

    func select(_ itemID: SidebarItem.ID?) {
        selectedItemID = itemID
        currentFolder = nil
    }

    func signIn(with session: AccountSession) throws {
        try Keychain.save(session)
        UserDefaults.standard.set(session.email, forKey: Self.accountKey)
        let source = Source(account: session)
        account = source
        Task {
            await source.load()
            select(accountItems.first?.id)
        }
    }

    func signOut() {
        if case .account(let session)? = account?.kind {
            Keychain.remove(email: session.email)
        }
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        account = nil
        select(linkItems.first?.id)
    }

    func download(_ nodes: [MegaNode], from source: Source) {
        guard !nodes.isEmpty else { return }
        transfers.download(nodes, from: source, into: Preferences.downloadDirectory)
    }

    func downloadEverything(from source: Source) {
        download(source.tree?.roots ?? [], from: source)
    }

    func uploadTarget(in source: Source) -> String? {
        guard source.allowsUpload, let folder,
              let node = source.tree?.node(folder),
              node.kind == .root || node.kind == .folder
        else { return nil }
        return folder
    }

    func isInRubbish(_ source: Source) -> Bool {
        guard let folder, let tree = source.tree else { return false }
        return tree.path(to: folder).first?.kind == .rubbish
    }

    func rubbishHandle(in source: Source) -> String? {
        source.tree?.roots.first { $0.kind == .rubbish }?.handle
    }

    func restoreDestination(for node: MegaNode, in source: Source) -> MegaNode? {
        guard let handle = node.restoreHandle, let target = source.tree?.node(handle),
              target.isDirectory, source.tree?.path(to: handle).first?.kind != .rubbish
        else { return nil }
        return target
    }

    func title(for source: Source) -> String {
        guard let folder, let node = source.tree?.node(folder) else { return source.name }
        return node.name
    }

    func isSingleFile(_ source: Source) -> Bool {
        guard let tree = source.tree else { return false }
        return tree.roots.count == 1 && !tree.roots[0].isDirectory
    }

    func contents(of source: Source) -> [MegaNode] {
        guard let tree = source.tree else { return [] }
        if isSingleFile(source) { return tree.roots }
        guard let folder, tree.node(folder) != nil else { return [] }
        return tree.children(of: folder)
    }

    func open(_ node: MegaNode) {
        guard node.isDirectory else { return }
        currentFolder = node.handle
    }

    func goUp(in source: Source) {
        guard canGoUp, let folder else { return }
        currentFolder = source.tree?.node(folder)?.parentHandle
    }

    private func persistLinks() {
        UserDefaults.standard.set(links.compactMap { $0.link?.url.absoluteString }, forKey: Self.linksKey)
    }
}
