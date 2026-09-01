import Synchronization
import Foundation
import Testing
@testable import MegaKit

@Suite struct SegmentPartitioningTests {
    @Test func `never splits a MAC chunk across segments`() {
        let chunks = MegaChunking.chunks(fileSize: 30 << 20)
        for target in [1 << 20, 2 << 20, 8 << 20] {
            let segments = MegaChunking.segments(chunks: chunks, targetBytes: target)
            #expect(segments.first?.lowerBound == 0)
            #expect(segments.last?.upperBound == chunks.count)
            #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        }
    }

    @Test func `starts every segment on a 16-byte boundary`() {
        let chunks = MegaChunking.chunks(fileSize: 6_610_126)
        for segment in MegaChunking.segments(chunks: chunks, targetBytes: 2 << 20) {
            #expect(chunks[segment.lowerBound].offset % 16 == 0)
        }
    }

    @Test func `covers a file smaller than one segment with a single segment`() {
        let chunks = MegaChunking.chunks(fileSize: 111)
        #expect(MegaChunking.segments(chunks: chunks, targetBytes: 2 << 20) == [0..<1])
    }

    @Test func `produces nothing for an empty file`() {
        #expect(MegaChunking.segments(chunks: [], targetBytes: 1 << 20).isEmpty)
    }
}

@Suite struct PartialDownloadTests {
    @Test func `round-trips through its sidecar`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appending(path: "state")

        var state = PartialDownload(size: 1_500_000, chunkCount: 5)
        state.record(Data(repeating: 7, count: 16), forChunk: 0)
        state.record(Data(repeating: 9, count: 16), forChunk: 3)
        try state.write(to: url)

        let restored = try #require(PartialDownload(contentsOf: url, size: 1_500_000, chunkCount: 5))
        #expect(restored.completedChunks == 2)
        #expect(restored.isComplete(chunk: 0))
        #expect(restored.isComplete(chunk: 3))
        #expect(!restored.isComplete(chunk: 1))
        #expect(restored.completedBytes == 131_072 + 524_288)
    }

    @Test func `rejects a sidecar written for a different file`() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appending(path: "state")

        try PartialDownload(size: 1_500_000, chunkCount: 5).write(to: url)
        #expect(PartialDownload(contentsOf: url, size: 999, chunkCount: 5) == nil)
        #expect(PartialDownload(contentsOf: url, size: 1_500_000, chunkCount: 4) == nil)
    }

    @Test func `condenses only once every chunk is present`() {
        var state = PartialDownload(size: 262_144, chunkCount: 2)
        let key = Data(count: 16)
        state.record(Data(repeating: 1, count: 16), forChunk: 0)
        #expect(state.condensedMAC(key: key) == nil)
        state.record(Data(repeating: 2, count: 16), forChunk: 1)
        #expect(state.condensedMAC(key: key)?.count == 8)
    }
}

@Suite(.serialized) struct DownloadEngineLiveTests {
    private func descriptor(for handle: String) async throws -> (MegaSession, DownloadDescriptor) {
        let session = try MegaSession(link: try #require(MegaLink(Live.folderURL)))
        let tree = try await session.loadTree()
        let node = try #require(tree.nodesByHandle[handle])
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
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".\(DownloadEngine.partExtension)"))
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

    @Test(liveOnly) func `rejects a file whose MAC does not match its key`() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let (_, target) = try await descriptor(for: Live.smallFileHandle)
        let tampered = DownloadDescriptor(
            url: target.url,
            size: target.size,
            key: MegaFileKey(aesKey: target.key.aesKey, nonce: target.key.nonce, metaMAC: Data(count: 8)),
            name: target.name
        )

        await #expect(throws: MegaError.integrityCheckFailed) {
            try await DownloadEngine().download(tampered, to: scratch.appending(path: "tampered"))
        }
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
        let chunks = MegaChunking.chunks(fileSize: target.size)
        var state = PartialDownload(size: target.size, chunkCount: chunks.count)
        for index in 0..<(chunks.count - 1) {
            state.record(
                ChunkMAC.mac(
                    forChunk: Data(expected[chunks[index].range]),
                    key: target.key.aesKey, nonce: target.key.nonce
                ),
                forChunk: index
            )
        }
        try Data(expected).write(to: destination.appendingPathExtension(DownloadEngine.partExtension))
        try FileManager.default.createDirectory(at: engine.stateDirectory, withIntermediateDirectories: true)
        try state.write(to: engine.stateURL(for: destination))

        let firstReport = Mutex<Int?>(nil)
        try await engine.download(target, to: destination) { bytes in
            firstReport.withLock { if $0 == nil { $0 = bytes } }
        }

        #expect(try Data(contentsOf: destination) == expected)
        #expect(firstReport.withLock { $0 } == state.completedBytes)
        #expect(state.completedBytes > target.size - MegaChunking.maximumChunkSize - 1)
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
}
