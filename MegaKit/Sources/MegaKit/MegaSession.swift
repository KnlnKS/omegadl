import CommonCrypto
import Foundation

public actor MegaSession {
    private enum Context: Sendable {
        case publicFolder(key: AESBlock)
        case publicFile(handle: NodeHandle, key: MegaFileKey)
        case account(AccountSession)
    }

    private let api: APIClient
    private let context: Context

    public init(account: AccountSession) {
        api = APIClient(.account(sessionID: account.sessionID))
        context = .account(account)
    }

    public init(link: MegaLink) {
        switch link.kind {
        case .folder(let key):
            api = APIClient(.folder(link.handle))
            context = .publicFolder(key: key)
        case .file(let key):
            api = APIClient()
            context = .publicFile(handle: link.handle, key: key)
        }
    }

    public func loadTree() async throws -> MegaTree {
        switch context {
        case .publicFolder(let key):
            return try await MegaTree(listing: api.body(for: [FilesCommand.folderLink]), keyring: Keyring(folderKey: key))

        case .account(let account):
            return try await MegaTree(listing: api.body(for: [FilesCommand.account]), keyring: Keyring(account: account))

        case .publicFile(let handle, let key):
            let response: DownloadResponse = try await api.request(
                DownloadCommand(publicHandle: handle.description, wantsURL: false)
            )
            let name = response.at.flatMap { MegaTree.attributes($0, key: key.aesKey)?.name }
            var rows = MegaTree.Builder()
            rows.append(
                handle: handle, parent: nil, kind: .file, size: response.s, time: Int(Date.now.timeIntervalSince1970),
                name: name ?? handle.description, key: key
            )
            return rows.build()
        }
    }

    public func downloadDescriptor(for node: MegaNode) async throws -> DownloadDescriptor {
        guard let key = node.fileKey else { throw MegaError.decryptionFailed }

        let command: DownloadCommand = switch context {
        case .publicFolder, .account: DownloadCommand(node: node.id.description)
        case .publicFile(let handle, _): DownloadCommand(publicHandle: handle.description, wantsURL: true)
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
        to parent: NodeHandle,
        engine: UploadEngine = UploadEngine(),
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> MegaNode {
        let account = try signedIn()
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let ticket: UploadResponse = try await api.request(UploadCommand(s: size))
        guard let uploadURL = URL(string: ticket.p), uploadURL.scheme == "https" else {
            throw MegaError.malformedResponse
        }

        let draft = MegaFileKey(aesKey: .random(), nonce: AESBlock.random().lowHalf, metaMAC: .zero)
        let result = try await engine.transmit(fileAt: source, to: uploadURL, key: draft, size: size, onProgress: onProgress)

        let packed = MegaFileKey(aesKey: draft.aesKey, nonce: draft.nonce, metaMAC: result.metaMAC).packed
        let wrapped = (AES.encrypt(packed.head, key: account.masterKey), AES.encrypt(packed.tail, key: account.masterKey))
        return try await commit(
            NewNode(
                h: result.token,
                t: MegaNode.Kind.file.rawValue,
                a: MegaTree.encodedAttributes(name: name, key: draft.aesKey),
                k: withUnsafeBytes(of: wrapped, Base64URL.encode)
            ),
            to: parent, account: account
        )
    }

    public func createFolder(named name: String, in parent: NodeHandle) async throws -> MegaNode {
        let account = try signedIn()
        let key = AESBlock.random()
        return try await commit(
            NewNode(
                h: "xxxxxxxx",
                t: MegaNode.Kind.folder.rawValue,
                a: MegaTree.encodedAttributes(name: name, key: key),
                k: Base64URL.encode(AES.encrypt(key, key: account.masterKey))
            ),
            to: parent, account: account
        )
    }

    /// Moves every node under `parent` in one request. `recordingOrigin` saves each node's current
    /// parent, which becomes its `restoreTarget`.
    public func move(_ nodes: [MegaNode], to parent: NodeHandle, recordingOrigin: Bool = false) async throws {
        try await run(nodes.flatMap { node in
            let move = NodeCommand.move(node.id, to: parent)
            guard recordingOrigin, let origin = node.parent?.id, let key = node.attributeKey else { return [move] }
            let attributes = MegaTree.encodedAttributes(name: node.name, restoreHandle: origin, key: key)
            return [.setAttributes(of: node.id, to: attributes), move]
        })
    }

    /// Returns every node that has a `restoreTarget` to it, in one request.
    public func putBack(_ nodes: [MegaNode]) async throws {
        try await run(nodes.compactMap { node in node.restoreTarget.map { .move(node.id, to: $0.id) } })
    }

    public func delete(_ nodes: [MegaNode]) async throws {
        try await run(nodes.map { .delete($0.id) })
    }

    /// Sends node commands as one batch; the server applies each, and the first failure is thrown.
    private func run(_ commands: [NodeCommand]) async throws {
        _ = try signedIn()
        guard !commands.isEmpty else { return }
        _ = try await api.body(for: commands)
    }

    private func signedIn() throws -> AccountSession {
        guard case .account(let account) = context else { throw MegaError.notAuthenticated }
        return account
    }

    private func commit(_ node: NewNode, to parent: NodeHandle, account: AccountSession) async throws -> MegaNode {
        let body = try await api.body(for: [PutCommand(t: parent.description, n: [node])])
        guard let created = try MegaTree(listing: body, keyring: Keyring(account: account)).roots.first else {
            throw MegaError.malformedResponse
        }
        return created
    }
}
