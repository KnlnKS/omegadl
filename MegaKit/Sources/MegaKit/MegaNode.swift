import Foundation

/// A node in a `MegaTree`: the tree plus a row index. Every property reads one column.
public struct MegaNode: Identifiable, Sendable {
    public enum Kind: Int, Sendable {
        case file = 0
        case folder = 1
        case root = 2
        case inbox = 3
        case rubbish = 4

        var standardName: String? {
            switch self {
            case .root: "Cloud Drive"
            case .inbox: "Inbox"
            case .rubbish: "Rubbish"
            case .file, .folder: nil
            }
        }
    }

    public let tree: MegaTree
    let index: Int

    public var id: NodeHandle { tree.handles[index] }
    public var name: String { tree.names[index] }
    public var size: Int { tree.sizes[index] }
    public var modified: Date { Date(timeIntervalSince1970: TimeInterval(tree.times[index])) }
    public var kind: Kind { tree.extents[index].kind }
    public var isDirectory: Bool { kind != .file }
    /// Every node in this one's subtree, itself first.
    var subtree: Range<Int> { index..<tree.extents[index].end }

    /// Whether `node` is this node or lies beneath it.
    public func contains(_ node: MegaNode) -> Bool { subtree.contains(node.index) }

    /// Directories have size zero, so this sums every file beneath.
    public var totalSize: Int { tree.sizes[subtree].reduce(0, +) }

    public var parent: MegaNode? {
        let parent = tree.parents[index]
        return parent < 0 ? nil : tree[Int(parent)]
    }

    public var root: MegaNode {
        var node = self
        while let parent = node.parent { node = parent }
        return node
    }

    public var children: [MegaNode] { tree.nodes(hopping: (index + 1)..<subtree.upperBound) }

    /// Calls `body` with every file in this subtree and the folder it lands in when the subtree is
    /// mirrored under `directory`.
    public func forEachFile(under directory: URL, _ body: (MegaNode, _ folder: URL) -> Void) {
        var folders = [(end: Int, url: URL)]()
        for row in subtree {
            while let folder = folders.last, row >= folder.end { folders.removeLast() }
            let node = tree[row]
            let folder = folders.last?.url ?? directory
            if node.isDirectory {
                folders.append((node.subtree.upperBound, folder.appending(path: node.name)))
            } else {
                body(node, folder)
            }
        }
    }

    /// The folder this node was moved to the rubbish from, while it exists outside the rubbish.
    public var restoreTarget: MegaNode? {
        guard let target = tree.node(tree.restores[index]), target.isDirectory, target.root.kind != .rubbish else { return nil }
        return target
    }

    var fileKey: MegaFileKey? { isDirectory ? nil : tree.key(at: index) }

    var attributeKey: AESBlock? { tree.key(at: index)?.aesKey }
}
