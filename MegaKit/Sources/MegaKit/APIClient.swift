import CryptoKit
import Foundation

actor APIClient {
    /// Who requests act as.
    enum Scope: Sendable {
        case anonymous
        case account(sessionID: String)
        case folder(NodeHandle)
    }

    private static let gateway = URL(string: "https://g.api.mega.co.nz/cs")!
    private static let maxRetries = 4

    private let scope: Scope
    private var sequence = Int.random(in: 0..<1_000_000_000)

    init(_ scope: Scope = .anonymous) {
        self.scope = scope
    }

    func request<Command: Encodable & Sendable, Response: Decodable & Sendable>(
        _ command: Command
    ) async throws -> Response {
        try Self.decode(try await body(for: [command]))
    }

    /// The raw response body to a batch of commands, once it is known to hold no error code.
    func body<Command: Encodable & Sendable>(for commands: [Command]) async throws -> Data {
        sequence += 1
        let url = endpoint(id: sequence)
        let body = try JSONEncoder().encode(commands)

        var hashcash: String?
        for attempt in 0...Self.maxRetries {
            do {
                let data = try await send(body: body, to: url, hashcash: &hashcash)
                if let code = Self.errorCode(in: data) { throw MegaError.apiCode(code) }
                return data
            } catch MegaError.api(.again) where attempt < Self.maxRetries {
                try await Task.sleep(for: .seconds(1 << (attempt + 1)))
            }
        }
        throw MegaError.api(.again)
    }

    private func endpoint(id: Int) -> URL {
        var components = URLComponents(url: Self.gateway, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "id", value: String(id))]
        switch scope {
        case .anonymous: break
        case .account(let sessionID): items.append(URLQueryItem(name: "sid", value: sessionID))
        case .folder(let handle): items.append(URLQueryItem(name: "n", value: handle.description))
        }
        components.queryItems = items
        return components.url!
    }

    private func send(body: Data, to url: URL, hashcash: inout String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let hashcash { request.setValue(hashcash, forHTTPHeaderField: "X-Hashcash") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MegaError.malformedResponse }

        if hashcash == nil, let challenge = http.value(forHTTPHeaderField: "X-Hashcash") {
            hashcash = try await Self.solveHashcash(challenge: challenge)
            return try await send(body: body, to: url, hashcash: &hashcash)
        }
        guard http.statusCode == 200 else { throw MegaError.httpStatus(http.statusCode) }
        return data
    }

    /// MEGA reports failure as a bare negative number, or as a negative entry among a batch's results.
    /// Scanning stops at the first result that is not a number, so listings are never walked.
    static func errorCode(in data: Data) -> Int? {
        data.withUnsafeBytes { bytes in
            var scanner = JSONScanner(bytes)
            guard scanner.take(UInt8(ascii: "[")) else { return scanner.integer().flatMap { $0 < 0 ? $0 : nil } }
            while let result = scanner.integer() {
                if result < 0 { return result }
            }
            return nil
        }
    }

    static func decode<Response: Decodable>(_ data: Data) throws -> Response {
        guard let first = try? JSONDecoder().decode([Response].self, from: data).first else {
            throw MegaError.malformedResponse
        }
        return first
    }
}

extension APIClient {
    private static let tokenRepeats = 262_144
    private static let blockRepeats = 1_024

    /// Finds a 4-byte nonce whose SHA-256 over `nonce ‖ token × 262144` falls under the threshold.
    /// The tail is periodic, so workers share one cache-sized block of repeats and stride the nonces.
    @concurrent
    static func solveHashcash(challenge: String) async throws -> String {
        let parts = challenge.split(separator: ":")
        guard parts.count == 4, parts[0] == "1",
              let easiness = UInt8(parts[1]),
              let token = Base64URL.decode(String(parts[3])), token.count == 48
        else { throw MegaError.proofOfWorkFailed }

        let threshold = (UInt32(easiness & 63) << 1 | 1) << ((UInt32(easiness) >> 6) * 7 + 3)
        let block = Array(repeatElement(token, count: blockRepeats).joined())
        let workers = UInt32(ProcessInfo.processInfo.activeProcessorCount)

        return try await withThrowingTaskGroup(of: UInt32?.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    for nonce in stride(from: worker, to: 1 << 24, by: Int(workers)) {
                        try Task.checkCancellation()
                        var hasher = SHA256()
                        withUnsafeBytes(of: nonce.littleEndian) { hasher.update(bufferPointer: $0) }
                        block.withUnsafeBytes { tail in
                            for _ in 0..<(tokenRepeats / blockRepeats) { hasher.update(bufferPointer: tail) }
                        }
                        if hasher.finalize().withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self).bigEndian }) <= threshold {
                            return nonce
                        }
                    }
                    return nil
                }
            }
            for try await case let nonce? in group {
                group.cancelAll()
                return "1:\(parts[3]):\(withUnsafeBytes(of: nonce.littleEndian, Base64URL.encode))"
            }
            throw MegaError.proofOfWorkFailed
        }
    }
}
