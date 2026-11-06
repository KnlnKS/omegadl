import Foundation
import MegaKit

/// Unfinished downloads on disk. Saves run in order on a background queue; the file holds columns
/// because JSONEncoder writes those over ten times faster than an array of objects.
nonisolated enum TransferStore {
    private struct Snapshot: Codable {
        var sources: [SourceRef] = []
        var source: [Int] = []
        var handles: [NodeHandle] = []
        var names: [String] = []
        var sizes: [Int] = []
        var bytes: [Int] = []
        var paths: [String] = []
    }

    private static let queue = DispatchQueue(label: "TransferStore", qos: .utility)

    private static let url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory)
        .appending(path: Bundle.main.bundleIdentifier ?? "OmegaDL")
        .appending(path: "Transfers.json")

    /// The saved downloads, queued with serials from 1.
    static func load() -> [Transfer] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
              [saved.source.count, saved.names.count, saved.sizes.count, saved.bytes.count, saved.paths.count]
                  .allSatisfy({ $0 == saved.handles.count }),
              saved.source.allSatisfy(saved.sources.indices.contains)
        else { return [] }
        return saved.handles.indices.map { row in
            Transfer(
                serial: UInt32(row + 1), job: .download(saved.handles[row], destination: URL(filePath: saved.paths[row])),
                source: saved.sources[saved.source[row]], name: saved.names[row], size: saved.sizes[row], bytes: saved.bytes[row]
            )
        }
    }

    /// Saves the unfinished downloads in `transfers`, taking live byte counts from `progress`.
    static func save(_ transfers: [Transfer], progress: [UInt32: Int]) {
        queue.async {
            var snapshot = Snapshot()
            var sourceRows = [SourceRef: Int]()
            for transfer in transfers where !transfer.state.isFinished {
                guard case .download(let handle, let destination) = transfer.job else { continue }
                let source = sourceRows[transfer.source] ?? snapshot.sources.count
                if source == snapshot.sources.count {
                    sourceRows[transfer.source] = source
                    snapshot.sources.append(transfer.source)
                }
                snapshot.source.append(source)
                snapshot.handles.append(handle)
                snapshot.names.append(transfer.name)
                snapshot.sizes.append(transfer.size)
                snapshot.bytes.append(progress[transfer.serial] ?? transfer.bytes)
                snapshot.paths.append(destination.path)
            }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Blocks until every save so far is on disk.
    static func flush() {
        queue.sync {}
    }
}
