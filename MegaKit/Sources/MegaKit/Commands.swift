import Foundation

struct FilesCommand: Encodable, Sendable {
    static let account = FilesCommand(ca: nil)
    static let folderLink = FilesCommand(ca: 1)

    let a = "f"
    let c = 1
    let r = 1
    private let ca: Int?
}

struct DownloadCommand: Encodable, Sendable {
    let a = "g"
    let g: Int
    let ssl = 2
    let n: String?
    let p: String?

    init(node: String) {
        self.g = 1
        self.n = node
        self.p = nil
    }

    init(publicHandle: String, wantsURL: Bool) {
        self.g = wantsURL ? 1 : 0
        self.n = nil
        self.p = publicHandle
    }
}

struct DownloadResponse: Decodable, Sendable {
    let g: String?
    let s: Int
    let at: String?
}

struct UploadCommand: Encodable, Sendable {
    let a = "u"
    let ssl = 2
    let s: Int
    let ms = 0
    let r = 0
    let e = 0
}

struct UploadResponse: Decodable, Sendable {
    let p: String
}

struct NewNode: Encodable, Sendable {
    let h: String
    let t: Int
    let a: String
    let k: String
}

struct PutCommand: Encodable, Sendable {
    let a = "p"
    let t: String
    let n: [NewNode]
}

/// Changes one node; batches share one request.
struct NodeCommand: Encodable, Sendable {
    private let a: String
    private let n: NodeHandle
    private var t: NodeHandle?
    private var at: String?

    static func move(_ node: NodeHandle, to parent: NodeHandle) -> Self { Self(a: "m", n: node, t: parent) }
    static func delete(_ node: NodeHandle) -> Self { Self(a: "d", n: node) }
    static func setAttributes(of node: NodeHandle, to attributes: String) -> Self { Self(a: "a", n: node, at: attributes) }
}
