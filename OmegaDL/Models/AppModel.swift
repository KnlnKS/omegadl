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

    private(set) var account: Source?
    private(set) var picks: [FolderPick] = []

    var selectedItemID: SidebarItem.ID?
    var currentFolder: String?
    var isAddingLink = false
    var isSigningIn = false

    private static let accountKey = "SignedInEmail"

    var currentPick: FolderPick? {
        get { picks.first }
        set { if newValue == nil, !picks.isEmpty { picks.removeFirst() } }
    }

    private func restoreAccount() async {
        guard account == nil,
              let email = UserDefaults.standard.string(forKey: Self.accountKey),
              let stored = await Keychain.storedSession(email: email)
        else { return }
        account = Source(account: stored)
    }

    var sources: [Source] {
        account.map { [$0] } ?? []
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
        accountItems.first { $0.id == selectedItemID }
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
            selectedItemID = accountItems.first?.id
        }
    }

    func addLinks(_ text: String) async -> String? {
        let sources = MegaLink.links(in: text).compactMap { try? Source(link: $0) }
        guard !sources.isEmpty else { return "No MEGA links found in that text." }

        await withTaskGroup { group in
            for source in sources {
                group.addTask { await source.load() }
            }
        }

        var failures = [String]()
        for source in sources {
            guard let tree = source.tree,
                  let target = source.link?.selectedHandle.flatMap(tree.node) ?? tree.roots.first
            else {
                if case .failed(let message) = source.status {
                    failures.append(message)
                } else {
                    failures.append("That link opened nothing.")
                }
                continue
            }
            if target.isDirectory {
                picks.append(FolderPick(source: source, root: target, tree: tree))
            } else {
                download([target], from: source)
            }
        }

        guard let first = failures.first else { return nil }
        return failures.count == 1 ? first : "\(failures.count) of \(sources.count) links failed."
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
        select(nil)
    }

    func download(_ nodes: [MegaNode], from source: Source, including: Set<MegaNode.ID>? = nil) {
        guard !nodes.isEmpty else { return }
        transfers.download(nodes, from: source, into: Preferences.downloadDirectory, including: including)
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

    func contents(of source: Source) -> [MegaNode] {
        guard let tree = source.tree, let folder, tree.node(folder) != nil else { return [] }
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
}
