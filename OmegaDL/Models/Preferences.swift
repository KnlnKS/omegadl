import Foundation

enum Preferences {
    static let downloadPathKey = "DefaultDownloadPath"
    static let simultaneousTransfersKey = "SimultaneousTransfers"
    static let connectionsPerTransferKey = "ConnectionsPerTransfer"

    static let simultaneousTransfersDefault = 2
    static let connectionsPerTransferDefault = 8

    static var downloadDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: downloadPathKey), !path.isEmpty {
            let url = URL(filePath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return systemDownloads
    }

    static var systemDownloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory
    }

    static var simultaneousTransfers: Int {
        positive(simultaneousTransfersKey, or: simultaneousTransfersDefault)
    }

    static var connectionsPerTransfer: Int {
        positive(connectionsPerTransferKey, or: connectionsPerTransferDefault)
    }

    private static func positive(_ key: String, or fallback: Int) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : fallback
    }
}
