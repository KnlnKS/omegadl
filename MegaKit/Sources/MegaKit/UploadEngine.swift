import CommonCrypto
import Foundation

struct UploadResult: Sendable {
    let token: String
    let metaMAC: SIMD8<UInt8>
}

public struct UploadEngine: Sendable {
    public let maximumConnections: Int
    let segmentSize: Int
    let maximumAttempts: Int
    private let session: URLSession

    /// The engine is shared by up to `concurrentTransfers` uploads at once, possibly to one host.
    public init(maximumConnections: Int = 8, concurrentTransfers: Int = 1, segmentSize: Int = 2 << 20, maximumAttempts: Int = 5) {
        self.maximumConnections = max(1, maximumConnections)
        self.segmentSize = max(Chunking.step, segmentSize)
        self.maximumAttempts = maximumAttempts

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = self.maximumConnections * max(1, concurrentTransfers)
        configuration.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: configuration)
    }

    /// Encrypts with `key`, ignoring its `metaMAC`; the result carries the MAC computed on the way.
    @concurrent
    func transmit(
        fileAt source: URL,
        to uploadURL: URL,
        key: MegaFileKey,
        size: Int,
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> UploadResult {
        guard size > 0 else {
            let token = try await post(Data(), to: uploadURL, offset: 0)
            return UploadResult(token: try Self.token(from: token), metaMAC: .zero)
        }

        let file = try File(source, flags: O_RDONLY)
        defer { file.close() }
        var macs = [AESBlock](repeating: .zero, count: Chunking.count(fileSize: size))
        var segments = Chunking.Segments(fileSize: size, targetBytes: segmentSize)
        var completed = 0
        var token: Data?

        try await withThrowingTaskGroup(of: (chunks: Range<Int>, macs: [AESBlock], response: Data).self) { group in
            func submit() {
                guard let chunks = segments.next() else { return }
                group.addTask {
                    let bytes = Chunking.bytes(of: chunks, fileSize: size)
                    var body = Data(count: bytes.count)
                    let macs = try body.withUnsafeMutableBytes { buffer in
                        try file.read(into: buffer, at: bytes.lowerBound)
                        let macs = ChunkMAC.compute(UnsafeRawBufferPointer(buffer), chunks: chunks, fileSize: size, key: key)
                        Cryptor(kCCEncrypt, mode: kCCModeCTR, key: key.aesKey, iv: key.counter(atBlock: bytes.lowerBound / 16)).update(buffer)
                        return macs
                    }
                    return (chunks, macs, try await post(body, to: uploadURL, offset: bytes.lowerBound))
                }
            }
            for _ in 0..<maximumConnections { submit() }

            for try await (chunks, chunkMACs, response) in group {
                macs.replaceSubrange(chunks, with: chunkMACs)
                if !response.isEmpty { token = response }
                completed += Chunking.bytes(of: chunks, fileSize: size).count
                onProgress(completed)
                submit()
            }
        }

        guard let token else { throw MegaError.malformedResponse }
        return UploadResult(token: try Self.token(from: token), metaMAC: ChunkMAC.condense(macs, key: key.aesKey))
    }

    private func post(_ body: Data, to uploadURL: URL, offset: Int) async throws -> Data {
        var request = URLRequest(url: uploadURL.appendingPathComponent(String(offset)))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        return try await retrying(attempts: maximumAttempts) {
            let (data, response) = try await session.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else { throw MegaError.malformedResponse }
            guard http.statusCode == 200 else { throw MegaError.httpStatus(http.statusCode) }
            if let code = Int(String(decoding: data, as: UTF8.self)), code < 0 {
                throw MegaError.apiCode(code)
            }
            return data
        }
    }

    static func token(from body: Data) throws -> String {
        guard !body.isEmpty else { throw MegaError.malformedResponse }
        let isText = body.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"): true
            default: false
            }
        }
        return isText ? String(decoding: body, as: UTF8.self) : Base64URL.encode(body)
    }
}
