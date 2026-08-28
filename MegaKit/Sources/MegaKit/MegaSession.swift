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
            let response: FilesResponse = try await api.request(FilesCommand(scopedToFolderLink: true))
            return MegaTree(nodes: response.f.compactMap(decryptor.decrypt))

        case .account(let account):
            await api.setSessionID(account.sessionID)
            let response: FilesResponse = try await api.request(FilesCommand(scopedToFolderLink: false))
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

    public func upload(
        fileAt source: URL,
        as name: String,
        to parent: String,
        engine: UploadEngine = UploadEngine(),
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> MegaNode {
        guard case .account(let account) = context else { throw MegaError.notAuthenticated }

        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        let ticket: UploadResponse = try await api.request(UploadCommand(s: size))
        guard let uploadURL = URL(string: ticket.p), uploadURL.scheme == "https" else {
            throw MegaError.malformedResponse
        }

        let key = Data.random(count: 16)
        let nonce = Data.random(count: 8)
        let result = try await engine.transmit(
            fileAt: source, to: uploadURL, key: key, nonce: nonce, size: size, onProgress: onProgress
        )

        let fileKey = MegaFileKey(aesKey: key, nonce: nonce, metaMAC: result.metaMAC)
        let node = NewNode(
            h: result.token,
            t: MegaNode.Kind.file.rawValue,
            a: NodeDecryptor.encodedAttributes(name: name, key: key),
            k: Base64URL.encode(AES128.ecbEncrypt(fileKey.packed, key: account.masterKey))
        )
        return try await commit(node, to: parent)
    }

    public func createFolder(named name: String, in parent: String) async throws -> MegaNode {
        guard case .account(let account) = context else { throw MegaError.notAuthenticated }

        let key = Data.random(count: 16)
        let node = NewNode(
            h: "xxxxxxxx",
            t: MegaNode.Kind.folder.rawValue,
            a: NodeDecryptor.encodedAttributes(name: name, key: key),
            k: Base64URL.encode(AES128.ecbEncrypt(key, key: account.masterKey))
        )
        return try await commit(node, to: parent)
    }

    public func delete(_ node: MegaNode) async throws {
        guard case .account = context else { throw MegaError.notAuthenticated }
        let _: Int = try await api.request(DeleteCommand(n: node.handle))
    }

    private func commit(_ node: NewNode, to parent: String) async throws -> MegaNode {
        let response: PutResponse = try await api.request(PutCommand(t: parent, n: [node]))
        guard let created = response.f.first.flatMap(decryptor.decrypt) else {
            throw MegaError.malformedResponse
        }
        return created
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
