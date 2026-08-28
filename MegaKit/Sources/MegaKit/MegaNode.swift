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
    }

    public let handle: String
    public let parentHandle: String?
    public let owner: String?
    public let kind: Kind
    public let size: Int
    public let modified: Date
    public let name: String
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

    func unwrap(_ field: String) -> Data? {
        for segment in field.split(separator: "/") {
            let parts = segment.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let wrapping = keysByHandle[String(parts[0])] ?? fallbackKey,
                  let wrapped = Base64URL.decode(String(parts[1])),
                  wrapped.count == 16 || wrapped.count == 32
            else { continue }
            return AES128.ecbDecrypt(wrapped, key: wrapping)
        }
        return nil
    }

    func decrypt(_ raw: RawNode) -> MegaNode? {
        let kind = MegaNode.Kind(rawValue: raw.t) ?? .file
        var key: MegaNode.Key?

        if let field = raw.k, let unwrapped = unwrap(field) {
            switch kind {
            case .file:
                key = MegaFileKey(packed: unwrapped).map(MegaNode.Key.file)
            default:
                key = unwrapped.count >= 16 ? .folder(Data(unwrapped.prefix(16))) : nil
            }
        }

        let attributeKey = switch key {
        case .file(let fileKey): fileKey.aesKey
        case .folder(let folderKey): folderKey
        case nil: nil as Data?
        }

        return MegaNode(
            handle: raw.h,
            parentHandle: raw.p,
            owner: raw.u,
            kind: kind,
            size: raw.s ?? 0,
            modified: Date(timeIntervalSince1970: TimeInterval(raw.ts ?? 0)),
            name: attributeKey.flatMap { Self.name(from: raw.a, key: $0) } ?? kind.standardName ?? raw.h,
            key: key
        )
    }

    static func name(from attributes: String?, key: Data) -> String? {
        guard let attributes, let decoded = Base64URL.decode(attributes),
              !decoded.isEmpty, decoded.count % 16 == 0
        else { return nil }

        let plaintext = AES128.cbcDecrypt(decoded, key: key).prefix { $0 != 0 }
        guard plaintext.starts(with: Data("MEGA{".utf8)) else { return nil }

        struct Attributes: Decodable { let n: String? }
        let json = Data(plaintext.dropFirst(4))
        return (try? JSONDecoder().decode(Attributes.self, from: json))?.n
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

    public func descendants(of handle: String) -> [MegaNode] {
        children(of: handle).flatMap { [$0] + ($0.isDirectory ? descendants(of: $0.handle) : []) }
    }

    static func ordered(_ lhs: MegaNode, _ rhs: MegaNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
