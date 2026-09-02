import Foundation

enum TransferStore {
    struct Record: Codable {
        let ref: SourceRef
        let handle: String
        let name: String
        let size: Int
        let destination: URL
        let bytesCompleted: Int
    }

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: Bundle.main.bundleIdentifier ?? "OmegaDL")
            .appending(path: "Transfers.json")
    }

    static func load() -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    static func save(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
