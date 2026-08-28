import Foundation
import Testing
@testable import MegaKit

@Suite(.serialized) struct MainActorDownloadTests {
    @Test(liveOnly, .timeLimit(.minutes(1)))
    @MainActor
    func `downloads when driven from the main actor`() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "ma-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let session = try MegaSession(link: try #require(MegaLink(Live.folderURL)))
        let tree = try await session.loadTree()
        let node = try #require(tree.nodesByHandle[Live.largeFileHandle])
        let target = try await session.downloadDescriptor(for: node)

        let destination = scratch.appending(path: target.name)
        try await DownloadEngine().download(target, to: destination) { _ in }

        #expect(try Data(contentsOf: destination).count == Live.largeFileSize)
    }
}
