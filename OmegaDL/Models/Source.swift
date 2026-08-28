import Foundation
import MegaKit
import Observation

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
    private let session: MegaSession

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

    var symbol: String {
        switch status {
        case .failed: "exclamationmark.triangle"
        case .loading: "arrow.trianglehead.2.clockwise"
        default:
            switch kind {
            case .account: "person.crop.circle"
            case .link(let link): link.kind == .folder ? "folder" : "doc"
            }
        }
    }

    var link: MegaLink? {
        if case .link(let link) = kind { link } else { nil }
    }

    func load() async {
        guard status == .idle || status.isFailure else { return }
        status = .loading
        do {
            tree = try await session.loadTree()
            status = .loaded
        } catch {
            status = .failed(error.localizedDescription)
        }
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

    func descriptor(for node: MegaNode) async throws -> DownloadDescriptor {
        try await session.downloadDescriptor(for: node)
    }

    func createFolder(named name: String, in parent: String) async throws -> MegaNode {
        try await session.createFolder(named: name, in: parent)
    }

    func upload(
        fileAt url: URL, as name: String, to parent: String, onProgress: @escaping @Sendable (Int) -> Void
    ) async throws -> MegaNode {
        try await session.upload(fileAt: url, as: name, to: parent, onProgress: onProgress)
    }
}
