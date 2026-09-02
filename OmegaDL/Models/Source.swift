import Foundation
import MegaKit
import Observation

enum SourceRef: Codable, Hashable {
    case link(URL)
    case account(String)
}

@Observable
final class Source: Identifiable {
    enum Kind: Sendable {
        case link(MegaLink)
        case account(AccountSession)
    }

    enum Status: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    let id = UUID()
    let kind: Kind
    let session: MegaSession

    private(set) var tree: MegaTree?
    private(set) var status: Status = .idle

    init(link: MegaLink) throws {
        self.kind = .link(link)
        self.session = try MegaSession(link: link)
    }

    init(account: AccountSession) {
        self.kind = .account(account)
        self.session = MegaSession(account: account)
    }

    var name: String {
        switch kind {
        case .link(let link): tree?.roots.first?.name ?? link.handle
        case .account(let account): account.email
        }
    }

    var link: MegaLink? {
        if case .link(let link) = kind { link } else { nil }
    }

    var ref: SourceRef {
        switch kind {
        case .link(let link): .link(link.url)
        case .account(let account): .account(account.email)
        }
    }

    private var loading: Task<Void, Never>?

    func load() async {
        if let loading { return await loading.value }
        guard status == .idle || status.isFailure else { return }

        let task = Task {
            status = .loading
            do {
                tree = try await session.loadTree()
                status = .loaded
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
        loading = task
        await task.value
        loading = nil
    }

    private(set) var isRefreshing = false

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let updated = try? await session.loadTree() { tree = updated }
    }

    var allowsUpload: Bool {
        if case .account = kind { true } else { false }
    }
}
