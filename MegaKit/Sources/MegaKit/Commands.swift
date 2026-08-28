import Foundation

struct FilesCommand: Encodable, Sendable {
    let a = "f"
    let c = 1
    let r = 1
    let ca: Int?

    init(scopedToFolderLink: Bool) {
        self.ca = scopedToFolderLink ? 1 : nil
    }
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

struct PutResponse: Decodable, Sendable {
    let f: [RawNode]
}

struct DeleteCommand: Encodable, Sendable {
    let a = "d"
    let n: String
}
