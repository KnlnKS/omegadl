import Foundation

public struct MegaNode: Sendable, Identifiable, Hashable {
    public enum Kind: Int, Sendable, Hashable {
        case file = 0
        case folder = 1
        case root = 2
        case inbox = 3
        case rubbish = 4

        public var standardName: String? {
            switch self {
            case .root: "Cloud Drive"
            case .inbox: "Inbox"
            case .rubbish: "Rubbish"
            case .file, .folder: nil
            }
        }
    }

    public enum Key: Sendable, Hashable {
        case file(MegaFileKey)
        case folder(Data)

        public var attributeKey: Data {
            switch self {
            case .file(let key): key.aesKey
            case .folder(let key): key
            }
        }
    }

    public let handle: String
    public let parentHandle: String?
    public let owner: String?
    public let kind: Kind
    public let size: Int
    public let modified: Date
    public let name: String
    public let restoreHandle: String?
    public let key: Key?

    public var id: String { handle }

    public var isDirectory: Bool { kind != .file }

    public var fileKey: MegaFileKey? {
        if case .file(let key) = key { key } else { nil }
    }

    public var folderKey: Data? {
        if case .folder(let key) = key { key } else { nil }
    }
}

struct RawNode: Decodable, Sendable {
    let h: String
    let p: String?
    let u: String?
    let t: Int
    let a: String?
    let k: String?
    let s: Int?
    let ts: Int?
}

public struct NodeDecryptor: Sendable {
    var keysByHandle: [String: Data]
    var fallbackKey: Data?

    public init(keysByHandle: [String: Data] = [:], fallbackKey: Data? = nil) {
        self.keysByHandle = keysByHandle
        self.fallbackKey = fallbackKey
    }

    public static func folderLink(key: Data) -> NodeDecryptor {
        NodeDecryptor(fallbackKey: key)
    }

    public static func account(userHandle: String, masterKey: Data, shareKeys: [String: Data]) -> NodeDecryptor {
        var keys = shareKeys
        keys[userHandle] = masterKey
        return NodeDecryptor(keysByHandle: keys)
    }

    func unwrap(_ field: String) -> [Data] {
        field.split(separator: "/").compactMap { segment in
            let parts = segment.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let wrapping = keysByHandle[String(parts[0])] ?? fallbackKey,
                  let wrapped = Base64URL.decode(String(parts[1])),
                  wrapped.count == 16 || wrapped.count == 32
            else { return nil }
            return AES128.ecbDecrypt(wrapped, key: wrapping)
        }
    }

    func decrypt(_ raw: RawNode) -> MegaNode? {
        let kind = MegaNode.Kind(rawValue: raw.t) ?? .file
        var key: MegaNode.Key?
        var attributes: NodeAttributes?

        for unwrapped in unwrap(raw.k ?? "") {
            let candidate: MegaNode.Key? = switch kind {
            case .file: MegaFileKey(packed: unwrapped).map(MegaNode.Key.file)
            default: unwrapped.count >= 16 ? .folder(Data(unwrapped.prefix(16))) : nil
            }
            guard let candidate else { continue }
            if key == nil { key = candidate }

            if let decoded = Self.attributes(from: raw.a, key: candidate.attributeKey) {
                key = candidate
                attributes = decoded
                break
            }
        }

        return MegaNode(
            handle: raw.h,
            parentHandle: raw.p,
            owner: raw.u,
            kind: kind,
            size: raw.s ?? 0,
            modified: Date(timeIntervalSince1970: TimeInterval(raw.ts ?? 0)),
            name: attributes?.n ?? kind.standardName ?? raw.h,
            restoreHandle: attributes?.rr,
            key: key
        )
    }

    struct NodeAttributes: Codable, Sendable {
        var n: String?
        var rr: String?
    }

    static func encodedAttributes(name: String, restoreHandle: String? = nil, key: Data) -> String {
        let attributes = NodeAttributes(n: name, rr: restoreHandle)
        let json = (try? JSONEncoder().encode(attributes)) ?? Data("{}".utf8)

        var plaintext = Data("MEGA".utf8) + json
        plaintext.append(Data(count: (16 - plaintext.count % 16) % 16))
        return Base64URL.encode(AES128.cbcEncrypt(plaintext, key: key))
    }

    static func attributes(from encoded: String?, key: Data) -> NodeAttributes? {
        guard let encoded, let decoded = Base64URL.decode(encoded),
              !decoded.isEmpty, decoded.count % 16 == 0
        else { return nil }

        let plaintext = AES128.cbcDecrypt(decoded, key: key).prefix { $0 != 0 }
        guard plaintext.starts(with: Data("MEGA{".utf8)) else { return nil }

        return try? JSONDecoder().decode(NodeAttributes.self, from: Data(plaintext.dropFirst(4)))
    }

    static func name(from encoded: String?, key: Data) -> String? {
        attributes(from: encoded, key: key)?.n
    }
}

public struct MegaTree: Sendable {
    public let nodesByHandle: [String: MegaNode]
    private let childrenByParent: [String: [MegaNode]]
    public let roots: [MegaNode]

    public init(nodes: [MegaNode]) {
        let byHandle = Dictionary(nodes.map { ($0.handle, $0) }, uniquingKeysWith: { _, latest in latest })
        let grouped = Dictionary(grouping: nodes.filter { byHandle[$0.parentHandle ?? ""] != nil }) {
            $0.parentHandle!
        }

        self.nodesByHandle = byHandle
        self.childrenByParent = grouped.mapValues { $0.sorted(by: MegaTree.ordered) }
        self.roots = nodes.filter { byHandle[$0.parentHandle ?? ""] == nil }.sorted(by: MegaTree.ordered)
    }

    public func children(of handle: String) -> [MegaNode] {
        childrenByParent[handle] ?? []
    }

    public func node(_ handle: String) -> MegaNode? {
        nodesByHandle[handle]
    }

    public func path(to handle: String) -> [MegaNode] {
        var path = [MegaNode]()
        var current = nodesByHandle[handle]
        while let node = current {
            path.append(node)
            current = node.parentHandle.flatMap { nodesByHandle[$0] }
        }
        return path.reversed()
    }

    static func ordered(_ lhs: MegaNode, _ rhs: MegaNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
