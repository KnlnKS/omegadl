import Foundation
import MegaKit
import Observation

enum SidebarSelection: Hashable {
    case folder(NodeHandle)
    case transfers
}

@Observable
final class AppModel {
    enum Sheet: Hashable, Identifiable {
        case addLink
        case signIn
        case pick(FolderPick)

        var id: Self { self }
    }

    let transfers = TransferManager()

    private(set) var account: Source?
    var selection: SidebarSelection?
    private(set) var sheet: Sheet?
    /// Folder picks from added links, shown one at a time as sheets close.
    @ObservationIgnored private var queuedPicks: [FolderPick] = []

    func present(_ sheet: Sheet) {
        self.sheet = sheet
    }

    func dismissSheet() {
        sheet = queuedPicks.isEmpty ? nil : .pick(queuedPicks.removeFirst())
    }

    /// Restores the saved account, resumes transfers, loads the tree and opens its first folder.
    func load() async {
        if account == nil, let session = await Keychain.standard.session() {
            open(session)
        }
        transfers.pump()
        await account?.load()
        if selection == nil {
            selection = account?.tree?.roots.first.map { .folder($0.id) }
        }
    }

    /// Opens each link, queuing a pick for folders and downloading files. Returns the links that failed.
    func addLinks(_ links: [MegaLink]) async -> [(link: MegaLink, message: String)] {
        let sources = links.map(Source.init(link:))
        await withTaskGroup { group in
            for source in sources {
                group.addTask { await source.load() }
            }
        }

        var failures = [(link: MegaLink, message: String)]()
        for (link, source) in zip(links, sources) {
            guard let tree = source.tree,
                  let target = link.selectedHandle.flatMap(tree.node) ?? tree.roots.first
            else {
                failures.append((link, source.failure ?? "That link opened nothing."))
                continue
            }
            if target.isDirectory {
                queuedPicks.append(FolderPick(source: source, root: target))
            } else {
                download([target], from: source)
                selection = .transfers
            }
        }

        return failures
    }

    func signIn(with session: AccountSession) throws {
        try Keychain.standard.save(session)
        open(session)
        Task { await load() }
    }

    func signOut() {
        guard let account else { return }
        transfers.drop(account)
        Keychain.standard.remove()
        self.account = nil
        if selection != .transfers { selection = nil }
    }

    private func open(_ session: AccountSession) {
        let source = Source(account: session)
        account = source
        transfers.register(source)
    }

    func download(_ nodes: [MegaNode], from source: Source) {
        guard !nodes.isEmpty else { return }
        transfers.download(nodes, from: source, into: Preferences.downloadDirectory)
    }

    func download(_ pick: FolderPick) {
        let chosen = pick.selection
        transfers.download([chosen.root], from: pick.source, into: Preferences.downloadDirectory, including: chosen.contains)
        selection = .transfers
    }
}
