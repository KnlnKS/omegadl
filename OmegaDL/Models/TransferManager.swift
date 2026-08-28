import AppKit
import Foundation
import MegaKit
import Observation

@Observable
final class Transfer: Identifiable {
    enum Kind {
        case download(node: MegaNode, destination: URL)
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
    let source: Source
    let name: String
    let size: Int

    var state: State = .queued
    var bytesCompleted = 0
    var bytesPerSecond: Double = 0
    var task: Task<Void, Never>?

    private var lastSample: (bytes: Int, time: ContinuousClock.Instant)?

    init(downloading node: MegaNode, to destination: URL, from source: Source) {
        self.kind = .download(node: node, destination: destination)
        self.source = source
        self.name = node.name
        self.size = node.size
    }

    init(uploading file: URL, to parent: String, from source: Source) {
        self.kind = .upload(file: file, parent: parent)
        self.source = source
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
        let now = ContinuousClock.now
        if let last = lastSample {
            let elapsed = now - last.time
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            if seconds > 0.05 {
                let instant = Double(bytes - last.bytes) / seconds
                bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
                lastSample = (bytes, now)
            }
        } else {
            lastSample = (bytes, now)
        }
        bytesCompleted = bytes
    }
}

@Observable
final class TransferManager {
    private(set) var transfers: [Transfer] = []
    private(set) var isPreparing = false

    private let uploads = UploadEngine()
    private var downloads = DownloadEngine(maximumConnections: Preferences.connectionsPerTransfer)
    private var engineConnections = Preferences.connectionsPerTransfer
    private var running = 0

    private var maximumConcurrent: Int { Preferences.simultaneousTransfers }

    private var downloadEngine: DownloadEngine {
        let wanted = Preferences.connectionsPerTransfer
        if wanted != engineConnections {
            engineConnections = wanted
            downloads = DownloadEngine(maximumConnections: wanted)
        }
        return downloads
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

    func download(_ nodes: [MegaNode], from source: Source, into directory: URL) {
        for node in nodes {
            if node.isDirectory {
                download(
                    source.tree?.children(of: node.handle) ?? [],
                    from: source,
                    into: directory.appending(path: node.name)
                )
            } else {
                transfers.append(Transfer(downloading: node, to: directory.appending(path: node.name), from: source))
            }
        }
        pump()
    }

    func upload(_ urls: [URL], to source: Source, parent: String) {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            for url in urls {
                await enqueue(url, to: source, parent: parent)
            }
            pump()
        }
    }

    private func enqueue(_ url: URL, to source: Source, parent: String) async {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        guard isDirectory.boolValue else {
            transfers.append(Transfer(uploading: url, to: parent, from: source))
            return
        }

        guard let folder = try? await source.createFolder(named: url.lastPathComponent, in: parent) else { return }
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

    func revealInFinder(_ transfer: Transfer) {
        guard let url = transfer.revealURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func pump() {
        while running < maximumConcurrent, let next = transfers.first(where: { $0.state == .queued }) {
            start(next)
        }
    }

    private func start(_ transfer: Transfer) {
        transfer.state = .running
        running += 1

        let id = transfer.id
        transfer.task = Task { [weak self] in
            guard let self else { return }
            let report: @Sendable (Int) -> Void = { bytes in
                Task { @MainActor [weak self] in self?.report(bytes: bytes, for: id) }
            }

            do {
                switch transfer.kind {
                case .download(let node, let destination):
                    let descriptor = try await transfer.source.descriptor(for: node)
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try await downloadEngine.download(descriptor, to: destination, onProgress: report)

                case .upload(let file, let parent):
                    _ = try await transfer.source.upload(
                        fileAt: file, as: transfer.name, to: parent, onProgress: report
                    )
                    await transfer.source.refresh()
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
        }
    }

    private func report(bytes: Int, for id: Transfer.ID) {
        transfers.first { $0.id == id }?.record(bytes: bytes)
    }
}
