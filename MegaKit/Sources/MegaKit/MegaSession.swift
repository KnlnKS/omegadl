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
    }

    private let api: APIClient
    private var decryptor: NodeDecryptor
    private let context: Context

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
        case .publicFolder: DownloadCommand(node: node.handle)
        case .publicFile(let handle, _): DownloadCommand(publicHandle: handle, wantsURL: true)
        }

        let response: DownloadResponse = try await api.request(command)
        guard let link = response.g, let url = URL(string: link), url.scheme?.hasPrefix("http") == true else {
            throw MegaError.malformedResponse
        }
        return DownloadDescriptor(url: url, size: response.s, key: key, name: node.name)
    }
}
