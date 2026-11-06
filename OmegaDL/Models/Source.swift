import Foundation
import MegaKit
import Observation

/// Saved as `{"link":{"url":…}}` or `{"account":{"email":…}}`.
nonisolated enum SourceRef: Codable, Hashable, Sendable {
    case link(url: String)
    case account(email: String)
}

@Observable
final class Source {
    enum State {
        case idle
        case loading
        case loaded(MegaTree)
        case failed(String)
    }

    let ref: SourceRef
    let session: MegaSession

    private(set) var state = State.idle
    @ObservationIgnored private var fetching: Task<Void, any Error>?
    /// Set when a refresh arrives mid-fetch, so the fetch runs again and reflects it.
    @ObservationIgnored private var isStale = false
    @ObservationIgnored private var pendingRefresh: Task<Void, any Error>?

    init(link: MegaLink) {
        ref = .link(url: link.url.absoluteString)
        session = MegaSession(link: link)
    }

    init(account: AccountSession) {
        ref = .account(email: account.email)
        session = MegaSession(account: account)
    }

    var tree: MegaTree? {
        if case .loaded(let tree) = state { tree } else { nil }
    }

    var failure: String? {
        if case .failed(let message) = state { message } else { nil }
    }

    /// Fetches the tree unless it is loaded or already loading.
    func load() async {
        if tree == nil, fetching == nil { fetch() }
        _ = await fetching?.result
    }

    /// Fetches a tree that reflects every change made before the call. A failure keeps the last tree.
    func refresh() async throws {
        if fetching == nil { fetch() } else { isStale = true }
        try await fetching?.value
    }

    /// Refreshes once activity settles, so a burst of uploads costs one listing.
    func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try await Task.sleep(for: .seconds(1))
            try await refresh()
        }
    }

    private func fetch() {
        if tree == nil { state = .loading }
        fetching = Task {
            defer { fetching = nil }
            repeat {
                isStale = false
                do {
                    state = .loaded(try await session.loadTree())
                } catch where !isStale {
                    if tree == nil { state = .failed(error.localizedDescription) }
                    throw error
                } catch {}
            } while isStale
        }
    }
}
