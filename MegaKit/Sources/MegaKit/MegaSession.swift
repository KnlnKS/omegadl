import Foundation

public struct DownloadDescriptor: Sendable {
    public let url: URL
    public let size: Int
    public let key: MegaFileKey
    public let name: String
}

public actor MegaSession {
    private enum Context: Sendable {
        case publicFolder(handle: String)
        case publicFile(handle: String, key: MegaFileKey)
        case account(AccountSession)
    }

    private let api: APIClient
    private var decryptor: NodeDecryptor
    private let context: Context

    public init(account: AccountSession, api: APIClient = APIClient()) {
        self.api = api
        self.context = .account(account)
        self.decryptor = NodeDecryptor()
    }

    public init(link: MegaLink, api: APIClient = APIClient()) throws {
        self.api = api
        switch link.kind {
        case .folder:
            self.context = .publicFolder(handle: link.handle)
            self.decryptor = .folderLink(key: link.key)
        case .file:
            guard let key = MegaFileKey(packed: link.key) else { throw MegaError.invalidLink }
            self.context = .publicFile(handle: link.handle, key: key)
            self.decryptor = NodeDecryptor()
        }
    }

    public func loadTree() async throws -> MegaTree {
        switch context {
        case .publicFolder(let handle):
            await api.setFolderID(handle)
            let response: FilesResponse = try await api.request(FilesCommand())
            return MegaTree(nodes: response.f.compactMap(decryptor.decrypt))

        case .account(let account):
            await api.setSessionID(account.sessionID)
            let response: FilesResponse = try await api.request(FilesCommand())
            decryptor = .account(
                userHandle: account.userHandle,
                masterKey: account.masterKey,
                shareKeys: Self.shareKeys(from: response.ok, masterKey: account.masterKey)
            )
            return MegaTree(nodes: response.f.compactMap(decryptor.decrypt))

        case .publicFile(let handle, let key):
            let response: DownloadResponse = try await api.request(
                DownloadCommand(publicHandle: handle, wantsURL: false)
            )
            let node = MegaNode(
                handle: handle,
                parentHandle: nil,
                owner: nil,
                kind: .file,
                size: response.s,
                modified: .now,
                name: NodeDecryptor.name(from: response.at, key: key.aesKey) ?? handle,
                key: .file(key)
            )
            return MegaTree(nodes: [node])
        }
    }

    public func downloadDescriptor(for node: MegaNode) async throws -> DownloadDescriptor {
        guard let key = node.fileKey else { throw MegaError.decryptionFailed }

        let command: DownloadCommand = switch context {
        case .publicFolder, .account: DownloadCommand(node: node.handle)
        case .publicFile(let handle, _): DownloadCommand(publicHandle: handle, wantsURL: true)
        }

        let response: DownloadResponse = try await api.request(command)
        guard let link = response.g, let url = URL(string: link), url.scheme == "https" else {
            throw MegaError.malformedResponse
        }
        return DownloadDescriptor(url: url, size: response.s, key: key, name: node.name)
    }

    static func shareKeys(from entries: [ShareKeyEntry]?, masterKey: Data) -> [String: Data] {
        var keys = [String: Data]()
        for entry in entries ?? [] {
            guard let wrapped = Base64URL.decode(entry.k), wrapped.count == 16 else { continue }
            let handle = Data(entry.h.utf8)
            if let authority = entry.ha.flatMap(Base64URL.decode) {
                guard handle.count == 8,
                      AES128.ecbEncrypt(handle + handle, key: masterKey) == authority
                else { continue }
            }
            keys[entry.h] = AES128.ecbDecrypt(wrapped, key: masterKey)
        }
        return keys
    }
}
