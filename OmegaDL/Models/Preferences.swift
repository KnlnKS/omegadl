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
        let stored = UserDefaults.standard.integer(forKey: simultaneousTransfersKey)
        return stored > 0 ? stored : simultaneousTransfersDefault
    }

    static var connectionsPerTransfer: Int {
        let stored = UserDefaults.standard.integer(forKey: connectionsPerTransferKey)
        return stored > 0 ? stored : connectionsPerTransferDefault
    }
}
