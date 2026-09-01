import Foundation
import MegaKit
import Observation

struct PickNode: Identifiable {
    let node: MegaNode
    let children: [PickNode]?
    let fileCount: Int
    let byteCount: Int

    var id: MegaNode.ID { node.id }

    init(node: MegaNode, in tree: MegaTree) {
        self.node = node
        guard node.isDirectory else {
            self.children = nil
            self.fileCount = 1
            self.byteCount = node.size
            return
        }
        let children = tree.children(of: node.handle).map { PickNode(node: $0, in: tree) }
        self.children = children
        self.fileCount = children.reduce(0) { $0 + $1.fileCount }
        self.byteCount = children.reduce(0) { $0 + $1.byteCount }
    }
}

@Observable
final class FolderPick: Identifiable {
    enum Check {
        case none
        case some
        case all
    }

    let id = UUID()
    let source: Source
    let root: PickNode

    private(set) var files: Set<MegaNode.ID> = []
    private(set) var bytes = 0
    private var chosen: [MegaNode.ID: Int] = [:]
    private var parents: [MegaNode.ID: MegaNode.ID] = [:]

    init(source: Source, root: MegaNode, tree: MegaTree) {
        self.source = source
        self.root = PickNode(node: root, in: tree)
        index(self.root, parent: nil)
        selectAll()
    }

    var count: Int { files.count }
    var total: Int { root.fileCount }

    func check(_ node: PickNode) -> Check {
        guard node.children != nil else { return files.contains(node.id) ? .all : .none }
        switch chosen[node.id] ?? 0 {
        case 0: return .none
        case node.fileCount: return .all
        default: return .some
        }
    }

    func toggle(_ node: PickNode) {
        if check(node) == .all { deselect(node) } else { select(node) }
    }

    func selectAll() {
        select(root)
    }

    func deselectAll() {
        deselect(root)
    }

    private func select(_ node: PickNode) {
        apply(node, selecting: true)
    }

    private func deselect(_ node: PickNode) {
        apply(node, selecting: false)
    }

    private func apply(_ node: PickNode, selecting: Bool) {
        var changed = 0
        var changedBytes = 0
        var stack = [node]
        while let next = stack.popLast() {
            if let children = next.children {
                stack.append(contentsOf: children)
            } else if selecting ? files.insert(next.id).inserted : files.remove(next.id) != nil {
                changed += 1
                changedBytes += next.byteCount
            }
        }
        guard changed > 0 else { return }

        let sign = selecting ? 1 : -1
        bytes += sign * changedBytes
        var folder = node.children == nil ? parents[node.id] : node.id
        while let handle = folder {
            chosen[handle, default: 0] += sign * changed
            folder = parents[handle]
        }
    }

    private func index(_ node: PickNode, parent: MegaNode.ID?) {
        parents[node.id] = parent
        for child in node.children ?? [] {
            index(child, parent: node.id)
        }
    }
}
