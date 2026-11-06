/// The files chosen under a folder, as bits over its subtree's rows. Every subtree is a contiguous
/// range of rows, so each count and toggle is a word-wise pass over one range.
public struct FileSelection: Sendable {
    public enum Check: Sendable {
        case none
        case some
        case all
    }

    public let root: MegaNode
    private let files: BitSet
    private var selected: BitSet

    /// Starts with every file selected.
    public init(root: MegaNode) {
        self.root = root
        files = BitSet(rows: root.subtree) { root.tree.extents[$0].kind == .file }
        selected = files
    }

    public var count: Int { selected.count(in: root.subtree) }
    public var total: Int { files.count(in: root.subtree) }

    public var bytes: Int {
        var total = 0
        selected.forEach(in: root.subtree) { total += root.tree.sizes[$0] }
        return total
    }

    public func contains(_ node: MegaNode) -> Bool {
        root.contains(node) && selected[node.index]
    }

    public func check(_ node: MegaNode) -> Check {
        switch selected.count(in: node.subtree) {
        case 0: .none
        case files.count(in: node.subtree): .all
        default: .some
        }
    }

    public mutating func toggle(_ node: MegaNode) {
        if check(node) == .all { selected.clear(node.subtree) } else { selected.assign(node.subtree, from: files) }
    }

    public mutating func selectAll() { selected = files }

    public mutating func deselectAll() { selected.clear(root.subtree) }
}

/// One bit per row of a range, operated on 64 bits at a time.
private struct BitSet {
    private let base: Int
    private var words: [UInt64]

    init(rows: Range<Int>, where predicate: (Int) -> Bool) {
        base = rows.lowerBound
        words = Array(repeating: 0, count: (rows.count + 63) / 64)
        for row in rows where predicate(row) { words[(row - base) >> 6] |= 1 << ((row - base) & 63) }
    }

    subscript(row: Int) -> Bool {
        words[(row - base) >> 6] & 1 << ((row - base) & 63) != 0
    }

    func count(in rows: Range<Int>) -> Int {
        var total = 0
        Self.forEachWord(in: rows, from: base) { word, mask in total += (words[word] & mask).nonzeroBitCount }
        return total
    }

    /// Copies `source`'s bits over this set's bits within `rows`.
    mutating func assign(_ rows: Range<Int>, from source: BitSet) {
        Self.forEachWord(in: rows, from: base) { word, mask in words[word] = words[word] & ~mask | source.words[word] & mask }
    }

    mutating func clear(_ rows: Range<Int>) {
        Self.forEachWord(in: rows, from: base) { word, mask in words[word] &= ~mask }
    }

    func forEach(in rows: Range<Int>, _ body: (Int) -> Void) {
        Self.forEachWord(in: rows, from: base) { word, mask in
            var bits = words[word] & mask
            while bits != 0 {
                body(base + (word << 6 | bits.trailingZeroBitCount))
                bits &= bits - 1
            }
        }
    }

    private static func forEachWord(in rows: Range<Int>, from base: Int, _ body: (_ word: Int, _ mask: UInt64) -> Void) {
        guard !rows.isEmpty else { return }
        let (low, high) = (rows.lowerBound - base, rows.upperBound - 1 - base)
        let (first, last) = (low >> 6, high >> 6)
        for word in first...last {
            var mask = UInt64.max
            if word == first { mask &= .max << (low & 63) }
            if word == last { mask &= .max >> (63 - (high & 63)) }
            body(word, mask)
        }
    }
}
