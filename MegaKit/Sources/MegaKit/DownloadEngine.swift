import CommonCrypto
import CryptoKit
import Foundation

public struct DownloadDescriptor: Sendable {
    public let url: URL
    public let size: Int
    public let key: MegaFileKey
    public let name: String
}

public struct DownloadEngine: Sendable {
    static let partExtension = "omegadl-part"

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

    /// The engine is shared by up to `concurrentTransfers` downloads at once, possibly from one host.
    public init(
        maximumConnections: Int = 8,
        concurrentTransfers: Int = 1,
        segmentSize: Int = 2 << 20,
        maximumAttempts: Int = 5,
        stateDirectory: URL = DownloadEngine.defaultStateDirectory
    ) {
        self.maximumConnections = max(1, maximumConnections)
        self.segmentSize = max(Chunking.step, segmentSize)
        self.maximumAttempts = maximumAttempts
        self.stateDirectory = stateDirectory

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = self.maximumConnections * max(1, concurrentTransfers)
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
        let size = descriptor.size
        let partURL = partURL(for: destination)
        let stateURL = stateURL(for: destination)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let resuming = FileManager.default.fileExists(atPath: partURL.path)
        let part = try File(partURL, flags: O_WRONLY | O_CREAT)
        defer { part.close() }
        try part.truncate(to: size)
        var sidecar = try Sidecar(stateURL, size: size, resuming: resuming)

        var completed = sidecar.macs.indices.reduce(0) { total, chunk in
            sidecar.macs[chunk] == .zero ? total : total + Chunking.bytes(of: chunk, fileSize: size).count
        }
        onProgress(completed)

        var pending = Chunking.Segments(fileSize: size, targetBytes: segmentSize)
            .filter { sidecar.macs[$0].contains(.zero) }
            .makeIterator()
        try await withThrowingTaskGroup(of: (chunks: Range<Int>, macs: [AESBlock]).self) { group in
            func submit() {
                guard let chunks = pending.next() else { return }
                group.addTask { (chunks, try await fetch(chunks, of: descriptor, into: part)) }
            }
            for _ in 0..<maximumConnections { submit() }

            for try await (chunks, macs) in group {
                try sidecar.record(macs, for: chunks)
                completed += Chunking.bytes(of: chunks, fileSize: size).count
                onProgress(completed)
                submit()
            }
        }

        guard size == 0 || ChunkMAC.condense(sidecar.macs, key: descriptor.key.aesKey) == descriptor.key.metaMAC else {
            try? FileManager.default.removeItem(at: stateURL)
            throw MegaError.integrityCheckFailed
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// Deletes what an unfinished download to `destination` kept for resuming.
    public func discardPartial(at destination: URL) {
        try? FileManager.default.removeItem(at: partURL(for: destination))
        try? FileManager.default.removeItem(at: stateURL(for: destination))
    }

    func partURL(for destination: URL) -> URL {
        destination.appendingPathExtension(Self.partExtension)
    }

    func stateURL(for destination: URL) -> URL {
        let digest = SHA256.hash(data: Data(destination.standardizedFileURL.path.utf8))
        return stateDirectory.appending(path: digest.withUnsafeBytes(Base64URL.encode) + ".state")
    }

    /// Fetches, decrypts and writes `chunks`, returning their MACs.
    private func fetch(_ chunks: Range<Int>, of descriptor: DownloadDescriptor, into file: File) async throws -> [AESBlock] {
        let bytes = Chunking.bytes(of: chunks, fileSize: descriptor.size)
        let ciphertext = try await fetchBytes(from: descriptor.url, range: bytes)
        guard ciphertext.count == bytes.count else { throw MegaError.malformedResponse }

        let ctr = Cryptor(kCCEncrypt, mode: kCCModeCTR, key: descriptor.key.aesKey, iv: descriptor.key.counter(atBlock: bytes.lowerBound / 16))
        return try withUnsafeTemporaryAllocation(byteCount: bytes.count, alignment: 16) { plaintext in
            var position = 0
            for region in ciphertext.regions {
                region.withUnsafeBytes { input in
                    guard let source = input.baseAddress else { return }
                    ctr.update(source, into: plaintext.baseAddress! + position, count: input.count)
                }
                position += region.count
            }
            try file.write(UnsafeRawBufferPointer(plaintext), at: bytes.lowerBound)
            return ChunkMAC.compute(UnsafeRawBufferPointer(plaintext), chunks: chunks, fileSize: descriptor.size, key: descriptor.key)
        }
    }

    private func fetchBytes(from url: URL, range: Range<Int>) async throws -> Data {
        let ranged = url.appendingPathComponent("\(range.lowerBound)-\(range.upperBound - 1)")

        return try await retrying(attempts: maximumAttempts) {
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
        }
    }
}

/// Resume state: a header, then one MAC slot per chunk at a fixed offset. A zero MAC marks a chunk
/// not yet fetched (a real CBC-MAC is zero with probability 2⁻¹²⁸), so each finished segment writes
/// only its own slots.
struct Sidecar: ~Copyable {
    private static let magic: UInt64 = 0x4F4D_444C_3200_0000
    private static let headerBytes = 16
    private let file: File
    private(set) var macs: [AESBlock]

    init(_ url: URL, size: Int, resuming: Bool) throws {
        try self.init(File(url, flags: O_RDWR | O_CREAT), size: size, resuming: resuming)
    }

    /// Owns `file` before anything can throw, so a failure closes it through `deinit`.
    private init(_ file: File, size: Int, resuming: Bool) throws {
        self.file = file
        macs = Array(repeating: .zero, count: Chunking.count(fileSize: size))
        let length = Self.headerBytes + macs.count * MemoryLayout<AESBlock>.stride
        let header = (Self.magic, UInt64(size))
        var stored = (UInt64(0), UInt64(0))

        if resuming, file.length == length {
            try withUnsafeMutableBytes(of: &stored) { try file.read(into: $0, at: 0) }
        }
        if stored == header {
            try macs.withUnsafeMutableBytes { try file.read(into: $0, at: Self.headerBytes) }
        } else {
            try file.truncate(to: 0)
            try file.truncate(to: length)
            try withUnsafeBytes(of: header) { try file.write($0, at: 0) }
        }
    }

    deinit { file.close() }

    mutating func record(_ chunkMACs: [AESBlock], for chunks: Range<Int>) throws {
        macs.replaceSubrange(chunks, with: chunkMACs)
        try chunkMACs.withUnsafeBytes { try file.write($0, at: Self.headerBytes + chunks.lowerBound * MemoryLayout<AESBlock>.stride) }
    }
}
