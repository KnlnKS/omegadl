import AppKit
import Foundation
import MegaKit
import Observation

@Observable
final class Transfer: Identifiable {
    enum Kind {
        case download(handle: String, destination: URL)
        case upload(file: URL, parent: String)
    }

    enum State: Equatable {
        case queued
        case running
        case completed
        case failed(String)
        case cancelled

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    let id = UUID()
    let kind: Kind
    let ref: SourceRef
    let name: String
    let size: Int

    var state: State = .queued
    var bytesCompleted = 0
    var bytesPerSecond: Double = 0
    var task: Task<Void, Never>?

    private var lastSample: (bytes: Int, time: ContinuousClock.Instant)?

    init(downloading node: MegaNode, to destination: URL, from source: Source) {
        self.kind = .download(handle: node.handle, destination: destination)
        self.ref = source.ref
        self.name = node.name
        self.size = node.size
    }

    init(uploading file: URL, to parent: String, from source: Source) {
        self.kind = .upload(file: file, parent: parent)
        self.ref = source.ref
        self.name = file.lastPathComponent
        self.size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    var isUpload: Bool {
        if case .upload = kind { true } else { false }
    }

    var revealURL: URL? {
        if case .download(_, let destination) = kind { destination } else { nil }
    }

    var fraction: Double {
        size > 0 ? min(1, Double(bytesCompleted) / Double(size)) : 0
    }

    var isFinished: Bool {
        switch state {
        case .completed, .failed, .cancelled: true
        case .queued, .running: false
        }
    }

    func record(bytes: Int) {
        defer { bytesCompleted = bytes }
        let now = ContinuousClock.now
        guard let last = lastSample else {
            lastSample = (bytes, now)
            return
        }
        let elapsed = now - last.time
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0.05 else { return }

        let instant = Double(bytes - last.bytes) / seconds
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
        lastSample = (bytes, now)
    }
}

struct TransferError: LocalizedError {
    let errorDescription: String?
}

@Observable
final class TransferManager {
    private(set) var transfers: [Transfer] = []

    private var downloads = DownloadEngine(maximumConnections: Preferences.connectionsPerTransfer)
    private var uploads = UploadEngine(maximumConnections: Preferences.connectionsPerTransfer)
    private var running = 0
    private var refreshes: [Source.ID: Task<Void, Never>] = [:]
    private var sources: [SourceRef: Source] = [:]

    func register(_ source: Source) {
        sources[source.ref] = source
    }

    private func source(for ref: SourceRef) throws -> Source {
        if let existing = sources[ref] { return existing }
        guard case .link(let url) = ref, let link = MegaLink(url.absoluteString) else {
            throw TransferError(errorDescription: "Sign in to resume this download.")
        }
        let source = try Source(link: link)
        sources[ref] = source
        return source
    }

    private func syncEngines() {
        let wanted = Preferences.connectionsPerTransfer
        guard wanted != downloads.maximumConnections else { return }
        downloads = DownloadEngine(maximumConnections: wanted)
        uploads = UploadEngine(maximumConnections: wanted)
    }

    var activeCount: Int {
        transfers.count { !$0.isFinished }
    }

    var aggregateFraction: Double {
        let active = transfers.filter { !$0.isFinished }
        let total = active.reduce(0) { $0 + $1.size }
        guard total > 0 else { return 0 }
        return Double(active.reduce(0) { $0 + $1.bytesCompleted }) / Double(total)
    }

    var aggregateBytesPerSecond: Double {
        transfers.filter { $0.state == .running }.reduce(0) { $0 + $1.bytesPerSecond }
    }

    func download(
        _ nodes: [MegaNode], from source: Source, into directory: URL, including: Set<MegaNode.ID>? = nil
    ) {
        register(source)
        enqueue(nodes, from: source, into: directory, including: including, skipping: claimed())
        pump()
    }

    private func enqueue(
        _ nodes: [MegaNode],
        from source: Source,
        into directory: URL,
        including: Set<MegaNode.ID>?,
        skipping: Set<MegaNode.ID>
    ) {
        for node in nodes {
            if node.isDirectory {
                enqueue(
                    source.tree?.children(of: node.handle) ?? [],
                    from: source,
                    into: directory.appending(path: node.name),
                    including: including,
                    skipping: skipping
                )
            } else if including?.contains(node.id) ?? true, !skipping.contains(node.id) {
                transfers.append(Transfer(downloading: node, to: directory.appending(path: node.name), from: source))
            }
        }
    }

    private func claimed() -> Set<MegaNode.ID> {
        Set(
            transfers.compactMap { transfer in
                guard case .download(let handle, _) = transfer.kind,
                      transfer.state != .cancelled, !transfer.state.isFailure
                else { return nil }
                return handle
            }
        )
    }

    func upload(_ urls: [URL], to source: Source, parent: String) {
        register(source)
        Task {
            for url in urls {
                await enqueue(url, to: source, parent: parent)
            }
            pump()
        }
    }

    private func enqueue(_ url: URL, to source: Source, parent: String) async {
        guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else { return }

        guard isDirectory else {
            transfers.append(Transfer(uploading: url, to: parent, from: source))
            return
        }

        guard let folder = try? await source.session.createFolder(named: url.lastPathComponent, in: parent) else { return }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            await enqueue(child, to: source, parent: folder.handle)
        }
    }

    func cancel(_ transfer: Transfer) {
        transfer.task?.cancel()
        if transfer.state == .queued {
            transfer.state = .cancelled
        }
    }

    func retry(_ transfer: Transfer) {
        guard transfer.isFinished, transfer.state != .completed else { return }
        transfer.state = .queued
        transfer.bytesPerSecond = 0
        pump()
    }

    func clearFinished() {
        transfers.removeAll { $0.isFinished }
    }

    func remove(_ transfer: Transfer) {
        cancel(transfer)
        transfers.removeAll { $0.id == transfer.id }
    }

    func revealInFinder(_ transfer: Transfer) {
        guard let url = transfer.revealURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func pump() {
        while running < Preferences.simultaneousTransfers,
              let next = transfers.first(where: { $0.state == .queued }) {
            start(next)
        }
    }

    private func start(_ transfer: Transfer) {
        syncEngines()
        transfer.state = .running
        running += 1

        let id = transfer.id
        transfer.task = Task { [weak self] in
            guard let self else { return }
            let report: @Sendable (Int) -> Void = { bytes in
                Task { @MainActor [weak self] in self?.report(bytes: bytes, for: id) }
            }

            do {
                let source = try self.source(for: transfer.ref)
                switch transfer.kind {
                case .download(let handle, let destination):
                    await source.load()
                    guard let node = source.tree?.node(handle) else {
                        throw TransferError(errorDescription: "That file is no longer available.")
                    }
                    let descriptor = try await source.session.downloadDescriptor(for: node)
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try await downloads.download(descriptor, to: destination, onProgress: report)

                case .upload(let file, let parent):
                    _ = try await source.session.upload(
                        fileAt: file, as: transfer.name, to: parent,
                        engine: uploads, onProgress: report
                    )
                }
                transfer.state = .completed
                transfer.bytesCompleted = transfer.size
            } catch is CancellationError {
                transfer.state = .cancelled
            } catch {
                transfer.state = .failed(error.localizedDescription)
            }
            running -= 1
            pump()
            if transfer.isUpload, let source = sources[transfer.ref] { scheduleRefresh(of: source) }
        }
    }

    private func scheduleRefresh(of source: Source) {
        refreshes[source.id]?.cancel()
        refreshes[source.id] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await source.refresh()
        }
    }

    private func report(bytes: Int, for id: Transfer.ID) {
        transfers.first { $0.id == id }?.record(bytes: bytes)
    }
}
