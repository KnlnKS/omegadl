import Foundation

private extension MegaFileKey {
    /// Stored for a node whose key could not be unwrapped; a real key is all zero with probability 2⁻²⁵⁶.
    static let missing = MegaFileKey(aesKey: .zero, nonce: .zero, metaMAC: .zero)
}

private extension MegaNode.Kind {
    /// Sort order among siblings and roots: Cloud Drive, Inbox, Rubbish, then folders, then files.
    var rank: Int {
        switch self {
        case .root: 0
        case .inbox: 1
        case .rubbish: 2
        case .folder: 3
        case .file: 4
        }
    }
}

/// Subtree end in the low 29 bits, kind in the top 3: traversal reads one column.
struct Extent: Sendable {
    private let raw: UInt32

    init(end: Int, kind: MegaNode.Kind) {
        raw = UInt32(end) | UInt32(kind.rawValue) << 29
    }

    var end: Int { Int(raw & 0x1FFF_FFFF) }
    var kind: MegaNode.Kind { MegaNode.Kind(rawValue: Int(raw >> 29))! }
}

/// A MEGA node tree as parallel columns in sorted depth-first preorder, siblings ordered by kind
/// rank then name. Each subtree is a contiguous range of rows, so membership is a range check.
public final class MegaTree: Sendable {
    let handles: [NodeHandle]
    let parents: [Int32]
    let extents: [Extent]
    let sizes: [Int]
    let times: [UInt32]
    let names: [String]
    private let keys: [MegaFileKey]
    let restores: [NodeHandle]
    /// Rows ordered by handle, for binary search.
    private let byHandle: [Int32]

    var count: Int { handles.count }

    subscript(index: Int) -> MegaNode { MegaNode(tree: self, index: index) }

    /// Root subtrees are laid end to end, so the roots are found by hopping extents.
    public var roots: [MegaNode] { nodes(hopping: 0..<count) }

    func nodes(hopping rows: Range<Int>) -> [MegaNode] {
        var nodes = [MegaNode]()
        var row = rows.lowerBound
        while row < rows.upperBound {
            nodes.append(self[row])
            row = extents[row].end
        }
        return nodes
    }

    func key(at index: Int) -> MegaFileKey? {
        keys[index] == .missing ? nil : keys[index]
    }

    public func node(_ handle: NodeHandle) -> MegaNode? {
        let slot = byHandle.partitioningIndex { handles[Int($0)] >= handle }
        return slot < byHandle.count && handles[Int(byHandle[slot])] == handle ? self[Int(byHandle[slot])] : nil
    }

    /// Rows as the server sent them; `build` resolves parents, sorts siblings and lays out preorder.
    struct Builder {
        var handles = [NodeHandle]()
        var parents = [NodeHandle]()
        var kinds = [MegaNode.Kind]()
        var sizes = [Int]()
        var times = [UInt32]()
        var names = [String]()
        var keys = [MegaFileKey]()
        var restores = [NodeHandle]()

        mutating func append(
            handle: NodeHandle, parent: NodeHandle?, kind: MegaNode.Kind, size: Int, time: Int,
            name: String, key: MegaFileKey? = nil, restore: NodeHandle? = nil
        ) {
            handles.append(handle)
            parents.append(parent ?? NodeHandle(raw: 0))
            kinds.append(kind)
            sizes.append(size)
            times.append(UInt32(clamping: time))
            names.append(name)
            keys.append(key ?? .missing)
            restores.append(restore ?? NodeHandle(raw: 0))
        }

        func build() -> MegaTree { MegaTree(self) }
    }

    init(_ rows: Builder) {
        let count = rows.handles.count

        // Sort (handle, row) once; it resolves parents, drops duplicate handles (last wins) and becomes the lookup.
        var sorted = (0..<count).map { (handle: rows.handles[$0], row: Int32($0)) }
        sorted.sort { ($0.handle, $0.row) < ($1.handle, $1.row) }
        sorted = sorted.indices.compactMap { index in
            index + 1 < sorted.count && sorted[index + 1].handle == sorted[index].handle ? nil : sorted[index]
        }
        func lookup(_ handle: NodeHandle) -> Int32? {
            let slot = sorted.partitioningIndex { $0.handle >= handle }
            return slot < sorted.count && sorted[slot].handle == handle ? sorted[slot].row : nil
        }

        // Children grouped per parent (CSR), then sorted once.
        var parentRow = [Int32](repeating: -1, count: count)
        var childCount = [Int32](repeating: 0, count: count + 1)
        var rootRows = [Int32]()
        for (_, row) in sorted {
            let parent = lookup(rows.parents[Int(row)]).flatMap { $0 == row ? nil : $0 }
            if let parent {
                parentRow[Int(row)] = parent
                childCount[Int(parent) + 1] += 1
            } else {
                rootRows.append(row)
            }
        }
        for index in 0..<count { childCount[index + 1] += childCount[index] }
        let childStart = childCount
        var children = [Int32](repeating: 0, count: Int(childCount[count]))
        var fill = childStart
        for row in 0..<count where parentRow[row] >= 0 {
            let parent = Int(parentRow[row])
            children[Int(fill[parent])] = Int32(row)
            fill[parent] += 1
        }

        func precedes(_ lhs: Int32, _ rhs: Int32) -> Bool {
            let (left, right) = (rows.kinds[Int(lhs)].rank, rows.kinds[Int(rhs)].rank)
            if left != right { return left < right }
            return rows.names[Int(lhs)].localizedStandardCompare(rows.names[Int(rhs)]) == .orderedAscending
        }
        for parent in 0..<count where childStart[parent + 1] - childStart[parent] > 1 {
            children[Int(childStart[parent])..<Int(childStart[parent + 1])].sort(by: precedes)
        }
        rootRows.sort(by: precedes)

        // Depth-first preorder. Rows unreachable from a root (cycles) are left out.
        var preorder = [Int32]()
        preorder.reserveCapacity(count)
        var position = [Int32](repeating: -1, count: count)
        var stack = Array(rootRows.reversed())
        while let row = stack.popLast() {
            position[Int(row)] = Int32(preorder.count)
            preorder.append(row)
            stack.append(contentsOf: children[Int(childStart[Int(row)])..<Int(childStart[Int(row) + 1])].reversed())
        }

        let parents = preorder.map { row in parentRow[Int(row)] < 0 ? -1 : position[Int(parentRow[Int(row)])] }
        var subtreeSize = [Int32](repeating: 1, count: preorder.count)
        for index in preorder.indices.reversed() where parents[index] >= 0 {
            subtreeSize[Int(parents[index])] += subtreeSize[index]
        }

        handles = preorder.map { rows.handles[Int($0)] }
        self.parents = parents
        extents = preorder.indices.map { Extent(end: $0 + Int(subtreeSize[$0]), kind: rows.kinds[Int(preorder[$0])]) }
        sizes = preorder.map { rows.sizes[Int($0)] }
        times = preorder.map { rows.times[Int($0)] }
        names = preorder.map { rows.names[Int($0)] }
        keys = preorder.map { rows.keys[Int($0)] }
        restores = preorder.map { rows.restores[Int($0)] }
        byHandle = sorted.compactMap { position[Int($0.row)] >= 0 ? position[Int($0.row)] : nil }
    }
}
