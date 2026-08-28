import Foundation
import MegaKit
import AppKit
import Observation

@Observable
final class Transfer: Identifiable {
    enum State: Equatable {
        case queued
        case running
        case completed
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let node: MegaNode
    let source: LinkSource
    let destination: URL

    var state: State = .queued
    var bytesCompleted = 0
    var bytesPerSecond: Double = 0
    var task: Task<Void, Never>?

    private var lastSample: (bytes: Int, time: ContinuousClock.Instant)?

    init(node: MegaNode, source: LinkSource, destination: URL) {
        self.node = node
        self.source = source
        self.destination = destination
    }

    var name: String { node.name }
    var size: Int { node.size }

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
            let seconds = Double((now - last.time).components.attoseconds) / 1e18
                + Double((now - last.time).components.seconds)
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

    private let engine = DownloadEngine()
    private let maximumConcurrent = 2
    private var running = 0

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

    func enqueue(_ nodes: [MegaNode], from source: LinkSource, into directory: URL) {
        for node in nodes {
            if node.isDirectory {
                enqueue(
                    source.tree?.children(of: node.handle) ?? [],
                    from: source,
                    into: directory.appending(path: node.name)
                )
            } else {
                transfers.append(
                    Transfer(node: node, source: source, destination: directory.appending(path: node.name))
                )
            }
        }
        pump()
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
        NSWorkspace.shared.activateFileViewerSelecting([transfer.destination])
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
            do {
                let descriptor = try await transfer.source.descriptor(for: transfer.node)
                try FileManager.default.createDirectory(
                    at: transfer.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await engine.download(descriptor, to: transfer.destination) { bytes in
                    Task { @MainActor [weak self] in self?.report(bytes: bytes, for: id) }
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
