import CryptoKit
import Darwin
import Foundation

public struct DownloadEngine: Sendable {
    public static let partExtension = "omegadl-part"

    public let maximumConnections: Int
    let segmentSize: Int
    let maximumAttempts: Int
    let stateDirectory: URL
    private let session: URLSession

    public static var defaultStateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: Bundle.main.bundleIdentifier ?? "MegaKit")
            .appending(path: "PartialDownloads")
    }

    public init(
        maximumConnections: Int = 8,
        segmentSize: Int = 2 << 20,
        maximumAttempts: Int = 5,
        stateDirectory: URL = DownloadEngine.defaultStateDirectory
    ) {
        self.maximumConnections = max(1, maximumConnections)
        self.segmentSize = max(MegaChunking.firstChunkSize, segmentSize)
        self.maximumAttempts = maximumAttempts
        self.stateDirectory = stateDirectory

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = self.maximumConnections
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    @concurrent
    public func download(
        _ descriptor: DownloadDescriptor,
        to destination: URL,
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async throws {
        let partURL = destination.appendingPathExtension(Self.partExtension)
        let stateURL = stateURL(for: destination)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let chunks = MegaChunking.chunks(fileSize: descriptor.size)

        let resumed = FileManager.default.fileExists(atPath: partURL.path)
            ? PartialDownload(contentsOf: stateURL, size: descriptor.size, chunkCount: chunks.count)
            : nil
        var state = resumed ?? PartialDownload(size: descriptor.size, chunkCount: chunks.count)

        let file = try FileSlot(url: partURL, size: descriptor.size)
        defer { file.close() }

        var completed = state.completedBytes
        onProgress(completed)

        let pending = Self.segments(chunks: chunks, targetBytes: segmentSize)
            .filter { range in range.contains { !state.isComplete(chunk: $0) } }

        if !pending.isEmpty {
            try await withThrowingTaskGroup(of: SegmentResult.self) { group in
                var next = 0
                func submit() {
                    guard next < pending.count else { return }
                    let range = pending[next]
                    next += 1
                    group.addTask {
                        try await fetch(
                            segment: range, chunks: chunks, descriptor: descriptor, into: file
                        )
                    }
                }
                for _ in 0..<min(maximumConnections, pending.count) { submit() }

                for try await result in group {
                    for (offset, mac) in result.macs.enumerated() {
                        state.record(mac, forChunk: result.range.lowerBound + offset)
                    }
                    completed += result.byteCount
                    onProgress(completed)
                    try? state.write(to: stateURL)
                    submit()
                }
            }
        }

        file.close()

        if descriptor.size > 0 {
            guard let mac = state.condensedMAC(key: descriptor.key.aesKey), mac == descriptor.key.metaMAC else {
                throw MegaError.integrityCheckFailed
            }
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
        try? FileManager.default.removeItem(at: stateURL)
    }

    public func stateURL(for destination: URL) -> URL {
        let digest = SHA256.hash(data: Data(destination.standardizedFileURL.path.utf8))
        return stateDirectory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".state")
    }

    private struct SegmentResult: Sendable {
        let range: Range<Int>
        let macs: [Data]
        let byteCount: Int
    }

    private func fetch(
        segment range: Range<Int>,
        chunks: [MegaChunk],
        descriptor: DownloadDescriptor,
        into file: FileSlot
    ) async throws -> SegmentResult {
        let start = chunks[range.lowerBound].offset
        let end = chunks[range.upperBound - 1].offset + chunks[range.upperBound - 1].length

        let ciphertext = try await fetchBytes(from: descriptor.url, start: start, end: end)
        guard ciphertext.count == end - start else { throw MegaError.malformedResponse }

        let plaintext = CTRCryptor(
            key: descriptor.key.aesKey, nonce: descriptor.key.nonce, blockOffset: UInt64(start / 16)
        ).process(ciphertext)

        try file.write(plaintext, at: start)

        let macs = range.map { index in
            let chunk = chunks[index]
            let local = (chunk.offset - start)..<(chunk.offset - start + chunk.length)
            return ChunkMAC.mac(
                forChunk: Data(plaintext[local]), key: descriptor.key.aesKey, nonce: descriptor.key.nonce
            )
        }
        return SegmentResult(range: range, macs: macs, byteCount: end - start)
    }

    private func fetchBytes(from url: URL, start: Int, end: Int) async throws -> Data {
        let ranged = url.appendingPathComponent("\(start)-\(end - 1)")

        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(from: ranged)
                guard let http = response as? HTTPURLResponse else { throw MegaError.malformedResponse }
                switch http.statusCode {
                case 200, 206:
                    return data
                case 509:
                    let seconds = http.value(forHTTPHeaderField: "x-mega-time-left").flatMap(TimeInterval.init)
                    throw MegaError.bandwidthExceeded(retryAfter: seconds)
                default:
                    throw MegaError.httpStatus(http.statusCode)
                }
            } catch let error as MegaError {
                if case .bandwidthExceeded = error { throw error }
                if attempt == maximumAttempts - 1 { throw error }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == maximumAttempts - 1 { throw error }
            }
            try await Task.sleep(for: .seconds(1 << attempt))
        }
        throw MegaError.httpStatus(0)
    }

    static func segments(chunks: [MegaChunk], targetBytes: Int) -> [Range<Int>] {
        var segments = [Range<Int>]()
        var start = 0
        var bytes = 0
        for (index, chunk) in chunks.enumerated() {
            bytes += chunk.length
            if bytes >= targetBytes || index == chunks.count - 1 {
                segments.append(start..<(index + 1))
                start = index + 1
                bytes = 0
            }
        }
        return segments
    }
}

final class FileSlot: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var isOpen = true

    init(url: URL, size: Int) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT, 0o644)
        }
        guard fd >= 0, ftruncate(fd, off_t(size)) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            throw MegaError.diskWriteFailed
        }
        self.descriptor = fd
    }

    func write(_ data: Data, at offset: Int) throws {
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { buffer -> Int in
                pwrite(descriptor, buffer.baseAddress! + written, data.count - written, off_t(offset + written))
            }
            guard result > 0 else { throw MegaError.diskWriteFailed }
            written += result
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if isOpen {
            Darwin.close(descriptor)
            isOpen = false
        }
    }
}
