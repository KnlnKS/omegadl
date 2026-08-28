import Foundation
import Testing
@testable import MegaKit

private struct Listing: Decodable { let f: [RawNode] }

private func decodedFixtureNodes() throws -> [MegaNode] {
    let listing = try JSONDecoder().decode(Listing.self, from: Data(folderListingJSON.utf8))
    let decryptor = NodeDecryptor.folderLink(key: try #require(Base64URL.decode(Live.folderKey)))
    return listing.f.compactMap(decryptor.decrypt)
}

@Suite struct NodeDecryptionTests {
    @Test func `decrypts every node in a real folder listing`() throws {
        let nodes = try decodedFixtureNodes()
        #expect(nodes.count == Live.nodeCount)
        #expect(nodes.allSatisfy { $0.key != nil })
        #expect(nodes.allSatisfy { $0.name != $0.handle })
    }

    @Test func `recovers the folder name and key`() throws {
        let root = try #require(try decodedFixtureNodes().first { $0.handle == Live.rootHandle })
        #expect(root.kind == .folder)
        #expect(root.name == Live.folderName)
        #expect(root.folderKey?.count == 16)
        #expect(root.fileKey == nil)
    }

    @Test func `recovers file names, sizes and keys`() throws {
        let nodes = try decodedFixtureNodes()

        let small = try #require(nodes.first { $0.handle == Live.smallFileHandle })
        #expect(small.kind == .file)
        #expect(small.name == Live.smallFileName)
        #expect(small.size == Live.smallFileSize)
        #expect(small.fileKey?.nonce.map { String(format: "%02x", $0) }.joined() == "8ae83362ce78b1e0")
        #expect(small.fileKey?.metaMAC.map { String(format: "%02x", $0) }.joined() == "9092af0f70214ec5")

        let large = try #require(nodes.first { $0.handle == Live.largeFileHandle })
        #expect(large.name == Live.largeFileName)
        #expect(large.size == Live.largeFileSize)
        #expect(large.modified.timeIntervalSince1970 > 0)
    }

    @Test func `yields no name when the key does not match`() throws {
        let listing = try JSONDecoder().decode(Listing.self, from: Data(folderListingJSON.utf8))
        let wrong = NodeDecryptor.folderLink(key: Data(count: 16))
        let nodes = listing.f.compactMap(wrong.decrypt)
        #expect(nodes.allSatisfy { $0.name == $0.handle })
    }

    @Test func `ignores key segments addressed to other holders`() throws {
        let listing = try JSONDecoder().decode(Listing.self, from: Data(folderListingJSON.utf8))
        let key = try #require(Base64URL.decode(Live.folderKey))
        let decryptor = NodeDecryptor.account(userHandle: "somebodyelse", masterKey: Data(count: 16), shareKeys: [
            Live.rootHandle: key
        ])
        let root = try #require(listing.f.first { $0.h == Live.rootHandle }.map(decryptor.decrypt))
        #expect(root?.name == Live.folderName)
    }
}

@Suite struct MegaTreeTests {
    @Test func `roots the tree at the shared folder`() throws {
        let tree = MegaTree(nodes: try decodedFixtureNodes())
        #expect(tree.roots.count == 1)
        #expect(tree.roots.first?.handle == Live.rootHandle)
        #expect(tree.children(of: Live.rootHandle).count == Live.nodeCount - 1)
        #expect(tree.children(of: Live.smallFileHandle).isEmpty)
    }

    @Test func `sorts directories first then by localized name`() throws {
        let nodes = [
            MegaNode(handle: "c", parentHandle: "r", owner: nil, kind: .file, size: 0,
                     modified: .distantPast, name: "beta.mp3", restoreHandle: nil, key: nil),
            MegaNode(handle: "b", parentHandle: "r", owner: nil, kind: .file, size: 0,
                     modified: .distantPast, name: "Alpha.mp3", restoreHandle: nil, key: nil),
            MegaNode(handle: "d", parentHandle: "r", owner: nil, kind: .folder, size: 0,
                     modified: .distantPast, name: "zeta", restoreHandle: nil, key: nil),
            MegaNode(handle: "r", parentHandle: nil, owner: nil, kind: .folder, size: 0,
                     modified: .distantPast, name: "root", restoreHandle: nil, key: nil),
        ]
        #expect(MegaTree(nodes: nodes).children(of: "r").map(\.name) == ["zeta", "Alpha.mp3", "beta.mp3"])
    }

    @Test func `builds a breadcrumb path from the root down`() throws {
        let tree = MegaTree(nodes: try decodedFixtureNodes())
        let path = tree.path(to: Live.largeFileHandle)
        #expect(path.map(\.handle) == [Live.rootHandle, Live.largeFileHandle])
    }

    @Test func `roots a lone file at itself with no children`() {
        let file = MegaNode(
            handle: "MQ10FZrA", parentHandle: nil, owner: nil, kind: .file, size: 6_370_825_656,
            modified: .distantPast, name: "episode.mkv", restoreHandle: nil, key: nil
        )
        let tree = MegaTree(nodes: [file])

        #expect(tree.roots.map(\.handle) == ["MQ10FZrA"])
        #expect(!tree.roots[0].isDirectory)
        #expect(tree.children(of: "MQ10FZrA").isEmpty)
        #expect(tree.path(to: "MQ10FZrA").map(\.handle) == ["MQ10FZrA"])
    }
}

@Suite struct ShareKeyTests {
    private let masterKey = Data((0..<16).map(UInt8.init))
    private let shareKey = Data((0..<16).map { UInt8(255 - $0) })

    private func entry(handle: String, authorized: Bool) -> ShareKeyEntry {
        let wrapped = AES128.ecbEncrypt(shareKey, key: masterKey)
        let authority = AES128.ecbEncrypt(Data(handle.utf8) + Data(handle.utf8), key: masterKey)
        return ShareKeyEntry(
            h: handle,
            k: Base64URL.encode(wrapped),
            ha: Base64URL.encode(authorized ? authority : Data(count: 16))
        )
    }

    @Test func `unwraps a share key whose authority checks out`() {
        let keys = MegaSession.shareKeys(from: [entry(handle: "AbCdEfGh", authorized: true)], masterKey: masterKey)
        #expect(keys["AbCdEfGh"] == shareKey)
    }

    @Test func `discards a share key whose authority was tampered with`() {
        let keys = MegaSession.shareKeys(from: [entry(handle: "AbCdEfGh", authorized: false)], masterKey: masterKey)
        #expect(keys.isEmpty)
    }

    @Test func `accepts an entry that carries no authority value`() {
        let wrapped = AES128.ecbEncrypt(shareKey, key: masterKey)
        let keys = MegaSession.shareKeys(
            from: [ShareKeyEntry(h: "AbCdEfGh", k: Base64URL.encode(wrapped), ha: nil)],
            masterKey: masterKey
        )
        #expect(keys["AbCdEfGh"] == shareKey)
    }
}
