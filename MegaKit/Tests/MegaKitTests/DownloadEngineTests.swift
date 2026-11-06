import Synchronization
import Foundation
import Testing
@testable import MegaKit

@Suite struct SidecarTests {
    private let size = 1_500_000

    @Test func `restores recorded MACs and leaves the rest missing`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appending(path: "state")

        var written = try Sidecar(url, size: size, resuming: false)
        try written.record([AESBlock(repeating: 7)], for: 0..<1)
        try written.record([AESBlock(repeating: 9)], for: 3..<4)

        let restored = try Sidecar(url, size: size, resuming: true)
        #expect(restored.macs == written.macs)
        #expect(restored.macs[1] == .zero)
    }

    @Test func `starts over for a different file or a fresh download`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appending(path: "state")

        var written = try Sidecar(url, size: size, resuming: false)
        try written.record([AESBlock(repeating: 7)], for: 0..<1)

        #expect(try Sidecar(url, size: size - 16, resuming: true).macs.allSatisfy { $0 == .zero })
        #expect(try Sidecar(url, size: size, resuming: false).macs.allSatisfy { $0 == .zero })
    }
}

@Suite(.serialized) struct DownloadEngineLiveTests {
    private func descriptor(for handle: String) async throws -> (MegaSession, DownloadDescriptor) {
        let session = MegaSession(link: try #require(MegaLink(Live.folderURL)))
        let tree = try await session.loadTree()
        let node = try #require(tree.node(NodeHandle(handle)!))
        return (session, try await session.downloadDescriptor(for: node))
    }

    @Test(liveOnly) func `downloads and verifies a single-chunk file`() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let (_, target) = try await descriptor(for: Live.smallFileHandle)
        let destination = scratch.appending(path: target.name)
        let engine = DownloadEngine(stateDirectory: scratch.appending(path: "state"))
        try await engine.download(target, to: destination)

        let data = try Data(contentsOf: destination)
        #expect(data.count == Live.smallFileSize)
        #expect(String(decoding: data.prefix(9), as: UTF8.self) == "[DEFAULT]")
        #expect(!FileManager.default.fileExists(atPath: engine.stateURL(for: destination).path))
        #expect(!FileManager.default.fileExists(atPath: engine.partURL(for: destination).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter {
            $0.hasSuffix(".state")
        }.isEmpty)
    }

    @Test(liveOnly) func `downloads a multi-segment file in parallel and verifies its MAC`() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let (_, target) = try await descriptor(for: Live.largeFileHandle)
        let destination = scratch.appending(path: target.name)

        let updates = Mutex<[Int]>([])
        try await DownloadEngine(maximumConnections: 8, segmentSize: 1 << 20)
            .download(target, to: destination) { bytes in updates.withLock { $0.append(bytes) } }

        let data = try Data(contentsOf: destination)
        #expect(data.count == Live.largeFileSize)
        #expect(data.prefix(3) == Data("ID3".utf8))

        let reported = updates.withLock { $0 }
        #expect(reported.count > 4)
        #expect(reported.last == Live.largeFileSize)
        #expect(reported == reported.sorted())
    }

    @Test(liveOnly) func `rejects a file whose MAC does not match its key and forgets its state`() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let (_, target) = try await descriptor(for: Live.smallFileHandle)
        let tampered = DownloadDescriptor(
            url: target.url,
            size: target.size,
            key: MegaFileKey(aesKey: target.key.aesKey, nonce: target.key.nonce, metaMAC: .zero),
            name: target.name
        )

        let engine = DownloadEngine(stateDirectory: scratch.appending(path: "state"))
        let destination = scratch.appending(path: "tampered")
        await #expect(throws: MegaError.integrityCheckFailed) {
            try await engine.download(tampered, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: engine.stateURL(for: destination).path))
    }

    @Test(liveOnly) func `resumes from a sidecar without refetching completed chunks`() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let (_, target) = try await descriptor(for: Live.largeFileHandle)
        let engine = DownloadEngine(stateDirectory: scratch.appending(path: "state"))
        let reference = scratch.appending(path: "reference")
        try await engine.download(target, to: reference)
        let expected = try Data(contentsOf: reference)

        let destination = scratch.appending(path: "resumed")
        let count = Chunking.count(fileSize: target.size)
        try expected.write(to: engine.partURL(for: destination))
        try FileManager.default.createDirectory(at: engine.stateDirectory, withIntermediateDirectories: true)
        var sidecar = try Sidecar(engine.stateURL(for: destination), size: target.size, resuming: false)
        try sidecar.record(chunkMACs(expected, key: target.key, chunks: 0..<(count - 1)), for: 0..<(count - 1))
        _ = consume sidecar

        let firstReport = Mutex<Int?>(nil)
        try await engine.download(target, to: destination) { bytes in
            firstReport.withLock { if $0 == nil { $0 = bytes } }
        }

        #expect(try Data(contentsOf: destination) == expected)
        #expect(firstReport.withLock { $0 } == Chunking.offset(of: count - 1))
    }
}

@Suite struct StateLocationTests {
    @Test func `keeps state out of the download folder`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let state = scratch.appending(path: "state")
        let engine = DownloadEngine(stateDirectory: state)
        let url = engine.stateURL(for: scratch.appending(path: "movie.mkv"))

        #expect(url.deletingLastPathComponent().path == state.path)
        #expect(url.pathExtension == "state")
        #expect(!url.lastPathComponent.contains("movie"))
    }

    @Test func `gives each destination its own state file`() throws {
        let engine = DownloadEngine(stateDirectory: URL(filePath: "/tmp/state"))
        let a = engine.stateURL(for: URL(filePath: "/a/movie.mkv"))
        let b = engine.stateURL(for: URL(filePath: "/b/movie.mkv"))

        #expect(a != b)
        #expect(a == engine.stateURL(for: URL(filePath: "/a/movie.mkv")))
        #expect(a == engine.stateURL(for: URL(filePath: "/a/./movie.mkv")))
    }

    @Test func `discards the part file and its state`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let engine = DownloadEngine(stateDirectory: scratch)
        let destination = scratch.appending(path: "movie.mkv")
        let leftovers = [engine.partURL(for: destination), engine.stateURL(for: destination)]
        for url in leftovers { try Data([1]).write(to: url) }

        engine.discardPartial(at: destination)
        #expect(leftovers.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}
