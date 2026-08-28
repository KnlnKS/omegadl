import Foundation
import Testing
@testable import MegaKit

@Suite(.serialized) struct MegaSessionLiveTests {
    @Test(liveOnly) func `loads a public folder tree from a link`() async throws {
        let session = try MegaSession(link: try #require(MegaLink(Live.folderURL)))
        let tree = try await session.loadTree()

        #expect(tree.nodesByHandle.count == Live.nodeCount)
        #expect(tree.roots.map(\.name) == [Live.folderName])
        #expect(tree.children(of: Live.rootHandle).count == Live.nodeCount - 1)
        #expect(tree.children(of: Live.rootHandle).contains { $0.name == Live.largeFileName })
    }

    @Test(liveOnly) func `resolves a download descriptor for a node in the folder`() async throws {
        let session = try MegaSession(link: try #require(MegaLink(Live.folderURL)))
        let tree = try await session.loadTree()
        let node = try #require(tree.nodesByHandle[Live.smallFileHandle])

        let descriptor = try await session.downloadDescriptor(for: node)
        #expect(descriptor.size == Live.smallFileSize)
        #expect(descriptor.name == Live.smallFileName)
        #expect(descriptor.key.metaMAC.count == 8)
        #expect(descriptor.url.scheme == "https")
    }

    @Test(liveOnly) func `refuses a download descriptor for a folder`() async throws {
        let session = try MegaSession(link: try #require(MegaLink(Live.folderURL)))
        let tree = try await session.loadTree()
        let root = try #require(tree.roots.first)

        await #expect(throws: MegaError.decryptionFailed) {
            _ = try await session.downloadDescriptor(for: root)
        }
    }
}
