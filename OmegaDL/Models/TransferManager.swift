import AppKit
import MegaKit
import Observation

nonisolated struct Transfer: Sendable {
    /// Queued and running transfers are active; the rest are finished.
    enum State: Sendable {
        case queued
        case running
        case completed
        case failed
        case cancelled

        var isFinished: Bool { self != .queued && self != .running }
    }

    enum Job: Sendable {
        case download(NodeHandle, destination: URL)
        case upload(URL, parent: NodeHandle)
        /// Creates the folder, then queues its contents.
        case uploadFolder(URL, parent: NodeHandle)
    }

    let serial: UInt32
    let job: Job
    let source: SourceRef
    let name: String
    let size: Int
    var state = State.queued
    /// Bytes done when the transfer last stopped; a run holds the live count.
    var bytes = 0
    var failure = ""

    var isUpload: Bool {
        if case .download = job { false } else { true }
    }

    var isFolder: Bool {
        if case .uploadFolder = job { true } else { false }
    }

    var destination: URL? {
        if case .download(_, let destination) = job { destination } else { nil }
    }
}

/// Transfers in serial order with running tallies, so counts, totals and the next queued row
/// never need a scan over every transfer.
struct TransferList {
    private(set) var transfers = [Transfer]()
    private(set) var finishedCount = 0
    private(set) var queued = (count: 0, size: 0, bytes: 0)
    /// No queued transfer sits before this index.
    private var queuedFloor = 0

    var activeCount: Int { transfers.count - finishedCount }

    func index(of serial: UInt32) -> Int? {
        let index = transfers.partitioningIndex { $0.serial >= serial }
        return index < transfers.count && transfers[index].serial == serial ? index : nil
    }

    /// Only valid while `queued.count > 0`.
    mutating func nextQueued() -> Int {
        queuedFloor = transfers[queuedFloor...].firstIndex { $0.state == .queued }!
        return queuedFloor
    }

    /// `batch` must continue the serial order.
    mutating func append(contentsOf batch: [Transfer]) {
        for transfer in batch { tally(transfer, 1) }
        transfers += batch
    }

    mutating func update(_ index: Int, _ change: (inout Transfer) -> Void) {
        tally(transfers[index], -1)
        change(&transfers[index])
        tally(transfers[index], 1)
        if transfers[index].state == .queued { queuedFloor = min(queuedFloor, index) }
    }

    mutating func remove(_ indices: RangeSet<Int>) {
        for transfer in transfers[indices] { tally(transfer, -1) }
        transfers.removeSubranges(indices)
        queuedFloor = 0
    }

    private mutating func tally(_ transfer: Transfer, _ sign: Int) {
        switch transfer.state {
        case .queued: queued = (queued.count + sign, queued.size + sign * transfer.size, queued.bytes + sign * transfer.bytes)
        case .running: break
        case .completed, .failed, .cancelled: finishedCount += sign
        }
    }
}

@Observable
final class TransferManager {
    /// State that exists only while a transfer runs, so progress touches nothing else.
    struct Run {
        let serial: UInt32
        let size: Int
        let task: Task<Void, Never>
        var bytes: Int
        var bytesPerSecond: Double = 0
        var sample: (bytes: Int, time: ContinuousClock.Instant)
    }

    private nonisolated static let uploadKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]

    private(set) var list = TransferList()
    private var runs = [Run]()
    @ObservationIgnored private var sources = [SourceRef: Source]()
    @ObservationIgnored private var nextSerial: UInt32 = 0
    @ObservationIgnored private var engines = TransferManager.engines()
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// Restores unfinished downloads as queued; `pump` starts them once their sources can be resolved.
    init() {
        let restored = TransferStore.load()
        nextSerial = restored.last?.serial ?? 0
        list.append(contentsOf: restored)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.save()
                TransferStore.flush()
            }
        }
    }

    /// Reading this ties a view to progress ticks, so only running rows should.
    func run(_ serial: UInt32) -> Run? {
        runs.first { $0.serial == serial }
    }

    var aggregateFraction: Double {
        let total = runs.reduce(list.queued.size) { $0 + $1.size }
        let done = runs.reduce(list.queued.bytes) { $0 + $1.bytes }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    var aggregateBytesPerSecond: Double { runs.reduce(0) { $0 + $1.bytesPerSecond } }

    func register(_ source: Source) {
        sources[source.ref] = source
    }

    /// Cancels and forgets every transfer from `source`, which must not be used again.
    func drop(_ source: Source) {
        sources[source.ref] = nil
        removeTransfers { $0.source == source.ref }
        scheduleSave()
    }

    private func source(for ref: SourceRef) throws -> Source {
        if let source = sources[ref] { return source }
        guard case .link(let url) = ref, let link = MegaLink(url) else {
            throw TransferError(errorDescription: "Sign in to resume this download.")
        }
        let source = Source(link: link)
        sources[ref] = source
        return source
    }

    /// Queues every file in `nodes`' subtrees, keeping their folder structure under `directory`.
    func download(_ nodes: [MegaNode], from source: Source, into directory: URL, including: (MegaNode) -> Bool = { _ in true }) {
        register(source)
        var claimed = claimedHandles()
        var batch = [Transfer]()
        for node in nodes {
            node.forEachFile(under: directory) { file, folder in
                guard including(file), claimed.insert(file.id).inserted else { return }
                batch.append(transfer(
                    .download(file.id, destination: folder.appending(path: file.name)),
                    name: file.name, size: file.size, source: source.ref
                ))
            }
        }
        enqueue(batch)
    }

    /// Handles already downloading or downloaded.
    private func claimedHandles() -> Set<NodeHandle> {
        var claimed = Set<NodeHandle>()
        for transfer in list.transfers where transfer.state != .cancelled && transfer.state != .failed {
            if case .download(let handle, _) = transfer.job { claimed.insert(handle) }
        }
        return claimed
    }

    func upload(_ urls: [URL], to source: Source, parent: NodeHandle) {
        register(source)
        enqueue(urls.map { uploadTransfer($0, to: parent, source: source.ref) })
    }

    private func uploadTransfer(_ url: URL, to parent: NodeHandle, source: SourceRef) -> Transfer {
        let values = try? url.resourceValues(forKeys: Self.uploadKeys)
        return transfer(
            values?.isDirectory == true ? .uploadFolder(url, parent: parent) : .upload(url, parent: parent),
            name: url.lastPathComponent, size: values?.fileSize ?? 0, source: source
        )
    }

    private func transfer(_ job: Transfer.Job, name: String, size: Int, source: SourceRef) -> Transfer {
        nextSerial += 1
        return Transfer(serial: nextSerial, job: job, source: source, name: name, size: size)
    }

    private func enqueue(_ batch: [Transfer]) {
        list.append(contentsOf: batch)
        pump()
        scheduleSave()
    }

    /// A running transfer stays running until its task unwinds, then finishes as cancelled.
    func cancel(_ serial: UInt32) {
        guard let index = list.index(of: serial) else { return }
        switch list.transfers[index].state {
        case .running:
            run(serial)?.task.cancel()
        case .queued:
            list.update(index) {
                $0.state = .cancelled
                $0.bytes = 0
            }
            discardPartial(of: list.transfers[index].job)
            scheduleSave()
        case .completed, .failed, .cancelled:
            break
        }
    }

    func retry(_ serial: UInt32) {
        guard let index = list.index(of: serial),
              list.transfers[index].state == .failed || list.transfers[index].state == .cancelled
        else { return }
        list.update(index) {
            $0.state = .queued
            $0.failure = ""
        }
        pump()
        scheduleSave()
    }

    func remove(_ serial: UInt32) {
        removeTransfers { $0.serial == serial && $0.state.isFinished }
    }

    func clearFinished() {
        removeTransfers { $0.state.isFinished }
    }

    /// Cancels the runs of removed transfers and deletes partial downloads nothing will resume.
    private func removeTransfers(where shouldRemove: (Transfer) -> Bool) {
        let indices = list.transfers.indices(where: shouldRemove)
        for transfer in list.transfers[indices] {
            switch transfer.state {
            case .running: run(transfer.serial)?.task.cancel()
            case .queued, .failed: discardPartial(of: transfer.job)
            case .completed, .cancelled: break
            }
        }
        list.remove(indices)
    }

    private func discardPartial(of job: Transfer.Job) {
        if case .download(_, let destination) = job { engines.downloads.discardPartial(at: destination) }
    }

    private static func engines() -> (downloads: DownloadEngine, uploads: UploadEngine) {
        let (connections, transfers) = (Preferences.connectionsPerTransfer, Preferences.simultaneousTransfersLimit)
        return (
            DownloadEngine(maximumConnections: connections, concurrentTransfers: transfers),
            UploadEngine(maximumConnections: connections, concurrentTransfers: transfers)
        )
    }

    /// Starts queued transfers while slots are free.
    func pump() {
        while runs.count < Preferences.simultaneousTransfers, list.queued.count > 0 {
            start(list.nextQueued())
        }
    }

    private func start(_ index: Int) {
        if engines.downloads.maximumConnections != Preferences.connectionsPerTransfer { engines = Self.engines() }

        list.update(index) { $0.state = .running }
        let transfer = list.transfers[index]
        let task = Task { await perform(transfer) }
        runs.append(Run(serial: transfer.serial, size: transfer.size, task: task, bytes: transfer.bytes, sample: (transfer.bytes, .now)))
    }

    private func perform(_ transfer: Transfer) async {
        let serial = transfer.serial
        let report: @Sendable (Int) -> Void = { bytes in
            Task { @MainActor in self.record(bytes, for: serial) }
        }
        var outcome = Transfer.State.completed
        var failure = ""
        do {
            let source = try source(for: transfer.source)
            switch transfer.job {
            case .download(let handle, let destination):
                await source.load()
                guard let node = source.tree?.node(handle) else {
                    throw TransferError(errorDescription: source.failure ?? "That file is no longer available.")
                }
                let descriptor = try await source.session.downloadDescriptor(for: node)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await engines.downloads.download(descriptor, to: destination, onProgress: report)

            case .upload(let file, let parent):
                _ = try await source.session.upload(fileAt: file, as: transfer.name, to: parent, engine: engines.uploads, onProgress: report)
                source.refreshSoon()

            case .uploadFolder(let folder, let parent):
                let contents = try await Self.contents(of: folder)
                let created = try await source.session.createFolder(named: transfer.name, in: parent)
                try Task.checkCancellation()
                enqueue(contents.map { uploadTransfer($0, to: created.id, source: transfer.source) })
                source.refreshSoon()
            }
        } catch where Task.isCancelled {
            outcome = .cancelled
            discardPartial(of: transfer.job)
        } catch {
            outcome = .failed
            failure = error.localizedDescription
        }
        finish(serial, outcome, failure: failure)
    }

    /// Lists a folder with the resource values `uploadTransfer` reads already fetched.
    @concurrent
    private static func contents(of folder: URL) async throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(uploadKeys), options: .skipsHiddenFiles)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func finish(_ serial: UInt32, _ state: Transfer.State, failure: String) {
        guard let slot = runs.firstIndex(where: { $0.serial == serial }) else { return }
        let run = runs.remove(at: slot)
        if let index = list.index(of: serial) {
            list.update(index) { transfer in
                transfer.state = state
                transfer.failure = failure
                transfer.bytes = switch state {
                case .completed: transfer.size
                case .cancelled: 0
                default: run.bytes
                }
            }
        }
        scheduleSave()
        pump()
    }

    private func record(_ bytes: Int, for serial: UInt32) {
        guard let slot = runs.firstIndex(where: { $0.serial == serial }) else { return }
        var run = runs[slot]
        run.bytes = bytes
        let now = ContinuousClock.now
        let seconds = (now - run.sample.time) / .seconds(1)
        if seconds > 0.05 {
            let instant = Double(bytes - run.sample.bytes) / seconds
            run.bytesPerSecond = run.bytesPerSecond == 0 ? instant : run.bytesPerSecond * 0.7 + instant * 0.3
            run.sample = (bytes, now)
        }
        runs[slot] = run
    }

    /// Coalesces bursts of structural changes into one write.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            pendingSave = nil
            save()
        }
    }

    private func save() {
        TransferStore.save(list.transfers, progress: Dictionary(uniqueKeysWithValues: runs.map { ($0.serial, $0.bytes) }))
    }
}

private struct TransferError: LocalizedError {
    let errorDescription: String?
}
