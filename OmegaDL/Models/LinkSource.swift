import Foundation
import MegaKit
import Observation

@Observable
final class LinkSource: Identifiable {
    enum Status: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let id = UUID()
    let link: MegaLink
    private let session: MegaSession

    private(set) var tree: MegaTree?
    private(set) var status: Status = .idle

    init(link: MegaLink) throws {
        self.link = link
        self.session = try MegaSession(link: link)
    }

    var name: String {
        tree?.roots.first?.name ?? link.handle
    }

    var rootHandle: String? {
        tree?.roots.first?.handle
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

    func descriptor(for node: MegaNode) async throws -> DownloadDescriptor {
        try await session.downloadDescriptor(for: node)
    }
}

extension LinkSource.Status {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}
