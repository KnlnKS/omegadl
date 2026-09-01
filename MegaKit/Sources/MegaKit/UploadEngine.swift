import Foundation

public struct UploadResult: Sendable {
    public let token: String
    public let metaMAC: Data
}

public struct UploadEngine: Sendable {
    private static let concurrentTransferHeadroom = 6

    public let maximumConnections: Int
    let segmentSize: Int
    let maximumAttempts: Int
    private let session: URLSession

    public init(maximumConnections: Int = 8, segmentSize: Int = 2 << 20, maximumAttempts: Int = 5) {
        self.maximumConnections = max(1, maximumConnections)
        self.segmentSize = max(MegaChunking.firstChunkSize, segmentSize)
        self.maximumAttempts = maximumAttempts

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = self.maximumConnections * Self.concurrentTransferHeadroom
        configuration.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: configuration)
    }

    @concurrent
    public func transmit(
        fileAt source: URL,
        to uploadURL: URL,
        key: Data,
        nonce: Data,
        size: Int,
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> UploadResult {
        guard size > 0 else {
            let token = try await post(Data(), to: uploadURL, offset: 0)
            return UploadResult(token: try Self.token(from: token), metaMAC: ChunkMAC.condense([], key: key))
        }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }

        let chunks = MegaChunking.chunks(fileSize: size)
        let cipher = CTRCryptor(key: key, nonce: nonce)
        var macs = [Data]()
        var completed = 0
        var tokens = [Data]()

        try await withThrowingTaskGroup(of: (Data, Int).self) { group in
            var inFlight = 0

            for segment in MegaChunking.segments(chunks: chunks, targetBytes: segmentSize) {
                try Task.checkCancellation()
                let offset = chunks[segment.lowerBound].offset
                let last = chunks[segment.upperBound - 1]
                let span = last.offset + last.length - offset
                guard let plaintext = try handle.read(upToCount: span), plaintext.count == span
                else { throw MegaError.diskWriteFailed }

                macs.append(
                    contentsOf: ChunkMAC.macs(
                        forSegment: plaintext, chunks: chunks[segment], key: key, nonce: nonce
                    )
                )
                let ciphertext = cipher.process(plaintext)

                if inFlight >= maximumConnections, let (body, length) = try await group.next() {
                    inFlight -= 1
                    if !body.isEmpty { tokens.append(body) }
                    completed += length
                    onProgress(completed)
                }

                group.addTask {
                    (try await post(ciphertext, to: uploadURL, offset: offset), ciphertext.count)
                }
                inFlight += 1
            }

            for try await (body, length) in group {
                if !body.isEmpty { tokens.append(body) }
                completed += length
                onProgress(completed)
            }
        }

        guard let raw = tokens.last else { throw MegaError.malformedResponse }
        return UploadResult(token: try Self.token(from: raw), metaMAC: ChunkMAC.condense(macs, key: key))
    }

    private func post(_ body: Data, to uploadURL: URL, offset: Int) async throws -> Data {
        var request = URLRequest(url: uploadURL.appendingPathComponent(String(offset)))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.upload(for: request, from: body)
                guard let http = response as? HTTPURLResponse else { throw MegaError.malformedResponse }
                guard http.statusCode == 200 else { throw MegaError.httpStatus(http.statusCode) }
                if let code = Int(String(decoding: data, as: UTF8.self)), code < 0 {
                    throw MegaError.apiCode(code)
                }
                return data
            } catch let error as MegaError {
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

    static func token(from body: Data) throws -> String {
        guard !body.isEmpty else { throw MegaError.malformedResponse }

        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        if body.allSatisfy(alphabet.contains) {
            return String(decoding: body, as: UTF8.self)
        }
        return Base64URL.encode(body)
    }
}

extension Data {
    static func random(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
