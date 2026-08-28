import Foundation

struct FilesCommand: Encodable, Sendable {
    let a = "f"
    let c = 1
    let ca = 1
    let r = 1
}

struct FilesResponse: Decodable, Sendable {
    let f: [RawNode]
    let sn: String?
    let ok: [ShareKeyEntry]?
}

struct ShareKeyEntry: Decodable, Sendable {
    let h: String
    let k: String
    let ha: String?
}

struct DownloadCommand: Encodable, Sendable {
    let a = "g"
    let g: Int
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
