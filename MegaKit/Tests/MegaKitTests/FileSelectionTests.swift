import Testing
@testable import MegaKit

@Suite struct FileSelectionTests {
    /// Cloud Drive ─ (aside/ ─ 3 files, top/ ─ (a/ ─ 100 files, b/ ─ 30 files, z)), so `top` starts
    /// mid-word and `a` spans several words.
    private let top: MegaNode = {
        var builder = MegaTree.Builder()
        var next: UInt64 = 0
        func add(_ name: String, _ kind: MegaNode.Kind, under parent: NodeHandle?, size: Int = 0) -> NodeHandle {
            next += 1
            let handle = NodeHandle(raw: next)
            builder.append(handle: handle, parent: parent, kind: kind, size: size, time: 0, name: name)
            return handle
        }
        let drive = add("Cloud Drive", .root, under: nil)
        let aside = add("aside", .folder, under: drive)
        for index in 0..<3 { _ = add("aside \(index)", .file, under: aside, size: 1000) }
        let top = add("top", .folder, under: drive)
        let a = add("a", .folder, under: top)
        for index in 0..<100 { _ = add("a \(index)", .file, under: a, size: 1) }
        let b = add("b", .folder, under: top)
        for index in 0..<30 { _ = add("b \(index)", .file, under: b, size: 10) }
        _ = add("z", .file, under: top, size: 100)
        return builder.build().node(top)!
    }()

    private var a: MegaNode { top.children[0] }
    private var b: MegaNode { top.children[1] }

    @Test func `starts with every file under the root and nothing else`() {
        let selection = FileSelection(root: top)
        #expect(selection.count == 131 && selection.total == 131)
        #expect(selection.bytes == 100 + 300 + 100)
        #expect(selection.check(top) == .all)
        #expect(!selection.contains(top.tree.roots[0].children.first { $0.name == "aside" }!.children[0]))
    }

    @Test func `toggles a folder's files and reports partial parents`() {
        var selection = FileSelection(root: top)
        selection.toggle(a)
        #expect(selection.count == 31 && selection.bytes == 400)
        #expect(selection.check(a) == .none && selection.check(b) == .all && selection.check(top) == .some)
        #expect(!selection.contains(a.children[63]) && !selection.contains(a.children[64]))

        selection.toggle(a.children[64])
        #expect(selection.check(a) == .some && selection.count == 32)
        selection.toggle(a)
        #expect(selection.check(a) == .all && selection.count == 131)
    }

    @Test func `selects and deselects everything`() {
        var selection = FileSelection(root: top)
        selection.deselectAll()
        #expect(selection.count == 0 && selection.bytes == 0 && selection.check(top) == .none)
        selection.toggle(b.children[0])
        selection.selectAll()
        #expect(selection.count == selection.total)
    }
}
