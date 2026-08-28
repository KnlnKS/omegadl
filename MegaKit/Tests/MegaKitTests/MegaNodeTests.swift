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
                     modified: .distantPast, name: "beta.mp3", key: nil),
            MegaNode(handle: "b", parentHandle: "r", owner: nil, kind: .file, size: 0,
                     modified: .distantPast, name: "Alpha.mp3", key: nil),
            MegaNode(handle: "d", parentHandle: "r", owner: nil, kind: .folder, size: 0,
                     modified: .distantPast, name: "zeta", key: nil),
            MegaNode(handle: "r", parentHandle: nil, owner: nil, kind: .folder, size: 0,
                     modified: .distantPast, name: "root", key: nil),
        ]
        #expect(MegaTree(nodes: nodes).children(of: "r").map(\.name) == ["zeta", "Alpha.mp3", "beta.mp3"])
    }

    @Test func `builds a breadcrumb path from the root down`() throws {
        let tree = MegaTree(nodes: try decodedFixtureNodes())
        let path = tree.path(to: Live.largeFileHandle)
        #expect(path.map(\.handle) == [Live.rootHandle, Live.largeFileHandle])
    }

    @Test func `walks every descendant of a folder`() throws {
        let tree = MegaTree(nodes: try decodedFixtureNodes())
        #expect(tree.descendants(of: Live.rootHandle).count == Live.nodeCount - 1)
    }
}
