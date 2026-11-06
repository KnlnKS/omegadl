import Foundation
import Testing
@testable import MegaKit

private let rootHandle = NodeHandle(Live.rootHandle)!

@Suite struct ListingTests {
    @Test func `decrypts every node in a real folder listing`() throws {
        let tree = try folderListingTree()
        #expect(tree.count == Live.nodeCount)
        #expect((0..<tree.count).allSatisfy { tree[$0].attributeKey != nil && tree[$0].name != tree[$0].id.description })
    }

    @Test func `recovers the folder name and key`() throws {
        let root = try #require(try folderListingTree().node(rootHandle))
        #expect(root.kind == .folder)
        #expect(root.name == Live.folderName)
        #expect(root.attributeKey != nil)
        #expect(root.fileKey == nil)
    }

    @Test func `recovers file names, sizes and keys`() throws {
        let tree = try folderListingTree()
        let small = try #require(tree.node(NodeHandle(Live.smallFileHandle)!))
        #expect(small.kind == .file)
        #expect(small.name == Live.smallFileName)
        #expect(small.size == Live.smallFileSize)
        #expect(small.fileKey?.nonce == half("8ae83362ce78b1e0"))
        #expect(small.fileKey?.metaMAC == half("9092af0f70214ec5"))

        let large = try #require(tree.node(NodeHandle(Live.largeFileHandle)!))
        #expect(large.name == Live.largeFileName)
        #expect(large.size == Live.largeFileSize)
        #expect(large.modified.timeIntervalSince1970 > 0)
    }

    @Test func `falls back to the handle when the key does not match`() throws {
        let tree = try folderListingTree(key: .zero)
        #expect((0..<tree.count).allSatisfy { tree[$0].name == tree[$0].id.description })
    }

    @Test func `reads a share root whose key is not the first segment`() throws {
        let decoy = "2X_iT56HQGc:" + Base64URL.encode(AES.encrypt(AESBlock(repeating: 7), key: AESBlock(repeating: 3)))
        let json = folderListingJSON.replacingOccurrences(of: #""k":"LIkEAD7L:q3Ls"#, with: #""k":"\#(decoy)/LIkEAD7L:q3Ls"#)
        #expect(try folderListingTree(json: json).node(rootHandle)?.name == Live.folderName)
    }

    @Test func `unwraps nodes through a share key from the account's key list`() throws {
        let masterKey = block("000102030405060708090a0b0c0d0e0f")
        let folderKey = try #require(Base64URL.decodeBlock(Live.folderKey))
        let share = #"{"h":"\#(Live.rootHandle)","k":"\#(Base64URL.encode(AES.encrypt(folderKey, key: masterKey)))"}"#
        let json = folderListingJSON.dropLast(2) + #"],"ok":[\#(share)]}"#
        let account = AccountSession(sessionID: "", masterKey: masterKey, userHandle: "somebodyelse", email: "")

        let tree = try MegaTree(listing: Data("[\(json)]".utf8), keyring: Keyring(account: account))
        #expect(tree.node(rootHandle)?.name == Live.folderName)
        #expect(tree.node(NodeHandle(Live.largeFileHandle)!)?.name == Live.largeFileName)
    }

    @Test func `rejects a body that is not a listing`() {
        #expect(throws: MegaError.malformedResponse) { try MegaTree(listing: Data("[]".utf8), keyring: Keyring(folderKey: .zero)) }
        #expect(throws: MegaError.malformedResponse) { try MegaTree(listing: Data(#"[{"f":[{"h":"#.utf8), keyring: Keyring(folderKey: .zero)) }
    }
}

@Suite struct MegaTreeTests {
    private func handle(_ index: Int) -> NodeHandle { NodeHandle(raw: UInt64(index + 1) * 0x0101_0101) }

    /// root ─ b/ ─ b1.txt, a/ ─ (a2.txt, a1/ ─ deep.txt), z.txt, plus a rubbish bin and an orphaned
    /// file and folder; appended shuffled.
    private func sampleTree() -> MegaTree {
        let rows: [(Int, Int?, MegaNode.Kind, String, Int)] = [
            (7, 3, .file, "deep.txt", 70), (2, 0, .folder, "b", 0), (0, nil, .root, "Cloud Drive", 0),
            (4, 1, .file, "a2.txt", 40), (5, 2, .file, "b1.txt", 50), (1, 0, .folder, "a", 0),
            (6, 0, .file, "z.txt", 60), (3, 1, .folder, "a1", 0), (8, nil, .rubbish, "Rubbish", 0),
            (9, 99, .file, "orphan.txt", 0), (10, 98, .folder, "Shared", 0),
        ]
        var builder = MegaTree.Builder()
        for (index, parent, kind, name, size) in rows {
            builder.append(handle: handle(index), parent: parent.map(handle), kind: kind, size: size, time: 0,
                           name: name)
        }
        return builder.build()
    }

    @Test func `orders system roots, then folders, then files, by localized name, depth first`() {
        let tree = sampleTree()
        #expect((0..<tree.count).map { tree[$0].name } == [
            "Cloud Drive", "a", "a1", "deep.txt", "a2.txt", "b", "b1.txt", "z.txt", "Rubbish", "Shared", "orphan.txt",
        ])
        #expect(tree.roots.map(\.kind) == [.root, .rubbish, .folder, .file])
        #expect(tree.roots[0].children.map(\.name) == ["a", "b", "z.txt"])
    }

    @Test func `lays out every subtree contiguously`() {
        let tree = sampleTree()
        for index in 0..<tree.count {
            let node = tree[index]
            #expect(node.children.allSatisfy { node.subtree.contains($0.index) && $0.subtree.upperBound <= node.subtree.upperBound })
            #expect(node.subtree.allSatisfy { tree[$0].root.index == node.root.index })
        }
        let a = tree.roots[0].children[0]
        #expect(a.totalSize == 110)
        #expect(tree.node(handle(7))?.parent?.parent?.id == handle(1))
    }

    @Test func `mirrors a subtree's files under a directory`() {
        var placed = [String]()
        sampleTree().roots[0].forEachFile(under: URL(filePath: "/d")) { file, folder in
            placed.append(folder.appending(path: file.name).path)
        }
        #expect(placed == ["/d/Cloud Drive/a/a1/deep.txt", "/d/Cloud Drive/a/a2.txt", "/d/Cloud Drive/b/b1.txt", "/d/Cloud Drive/z.txt"])
    }

    @Test func `finds every node by handle`() {
        let tree = sampleTree()
        for index in 0..<9 { #expect(tree.node(handle(index))?.id == handle(index)) }
        #expect(tree.node(handle(99)) == nil)
    }

    @Test func `keeps the last row for a repeated handle and drops cycles`() {
        var builder = MegaTree.Builder()
        builder.append(handle: handle(0), parent: nil, kind: .folder, size: 0, time: 0, name: "old")
        builder.append(handle: handle(0), parent: nil, kind: .folder, size: 0, time: 0, name: "new")
        builder.append(handle: handle(1), parent: handle(2), kind: .folder, size: 0, time: 0, name: "loop")
        builder.append(handle: handle(2), parent: handle(1), kind: .folder, size: 0, time: 0, name: "loop")
        let tree = builder.build()
        #expect(tree.count == 1)
        #expect(tree.roots.map(\.name) == ["new"])
    }

    @Test func `puts back only into an existing folder outside the rubbish`() {
        var builder = MegaTree.Builder()
        let rows: [(Int, Int?, MegaNode.Kind, Int?)] = [
            (0, nil, .root, nil), (1, 0, .folder, nil), (2, 0, .file, nil), (3, nil, .rubbish, nil), (4, 3, .folder, nil),
            (5, 3, .file, 1), (6, 3, .file, 2), (7, 3, .file, 4), (8, 3, .file, 99), (9, 3, .file, nil),
        ]
        for (index, parent, kind, restore) in rows {
            builder.append(handle: handle(index), parent: parent.map(handle), kind: kind, size: 0, time: 0,
                           name: "\(index)", restore: restore.map(handle))
        }
        let tree = builder.build()
        #expect(tree.node(handle(5))?.restoreTarget?.id == handle(1))
        #expect((6...9).allSatisfy { tree.node(handle($0))?.restoreTarget == nil })
    }

    @Test func `roots a lone file at itself`() {
        var builder = MegaTree.Builder()
        builder.append(handle: handle(0), parent: nil, kind: .file, size: 6_370_825_656, time: 0,
                       name: "episode.mkv")
        let file = builder.build().roots[0]
        #expect(!file.isDirectory)
        #expect(file.children.isEmpty)
        #expect(file.size == 6_370_825_656)
    }
}

@Suite struct KeyringTests {
    private let masterKey = block("000102030405060708090a0b0c0d0e0f")
    private let shareKey = block("fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0")
    private let share = NodeHandle("AbCdEfGh")!

    private func keyring(authority: AESBlock?) -> Keyring {
        var keyring = Keyring(account: AccountSession(sessionID: "", masterKey: masterKey, userHandle: "AAAAAAAAAAA", email: ""))
        keyring.addShare(handle: share, wrapped: AES.encrypt(shareKey, key: masterKey), authority: authority)
        return keyring
    }

    private func key(_ keyring: borrowing Keyring, for holder: String) -> AESBlock? {
        var holder = holder
        return holder.withUTF8 { keyring.wrappingKey(for: UnsafeRawBufferPointer($0)) }
    }

    @Test func `unwraps a share key whose authority checks out, or that carries none`() {
        let authority = AES.encrypt(AESBlock(Array("AbCdEfGhAbCdEfGh".utf8)), key: masterKey)
        #expect(key(keyring(authority: authority), for: "AbCdEfGh") == shareKey)
        #expect(key(keyring(authority: nil), for: "AbCdEfGh") == shareKey)
    }

    @Test func `discards a share key whose authority was tampered with`() {
        #expect(key(keyring(authority: .zero), for: "AbCdEfGh") == nil)
    }

    @Test func `resolves the owner's own handle to the master key and nobody else's`() {
        let keyring = keyring(authority: nil)
        #expect(key(keyring, for: "AAAAAAAAAAA") == masterKey)
        #expect(key(keyring, for: "BBBBBBBBBBB") == nil)
    }
}
