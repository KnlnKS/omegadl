import CryptoKit
import Foundation

public actor APIClient {
    private let gateway: URL
    private let session: URLSession
    private var sequence: Int
    private var sessionID: String?
    private var folderID: String?

    private static let maxRetries = 4

    public init(gateway: URL = URL(string: "https://g.api.mega.co.nz")!, session: URLSession = .shared) {
        self.gateway = gateway
        self.session = session
        self.sequence = Int.random(in: 0..<1_000_000_000)
    }

    public func setSessionID(_ id: String?) {
        sessionID = id
    }

    public func setFolderID(_ id: String?) {
        folderID = id
    }

    public func request<Command: Encodable & Sendable, Response: Decodable & Sendable>(
        _ command: Command
    ) async throws -> Response {
        sequence += 1
        let url = endpoint(id: sequence)
        let body = try JSONEncoder().encode([command])

        var hashcash: String?
        for attempt in 0...Self.maxRetries {
            do {
                let data = try await send(body: body, to: url, hashcash: &hashcash)
                guard let data else { continue }
                return try Self.decode(data)
            } catch MegaError.api(.again) where attempt < Self.maxRetries {
                try await Task.sleep(for: .seconds(1 << (attempt + 1)))
            }
        }
        throw MegaError.api(.again)
    }

    private func endpoint(id: Int) -> URL {
        var components = URLComponents(url: gateway.appendingPathComponent("cs"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "id", value: String(id))]
        if let sessionID { items.append(URLQueryItem(name: "sid", value: sessionID)) }
        if let folderID { items.append(URLQueryItem(name: "n", value: folderID)) }
        components.queryItems = items
        return components.url!
    }

    private func send(body: Data, to url: URL, hashcash: inout String?) async throws -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let hashcash { request.setValue(hashcash, forHTTPHeaderField: "X-Hashcash") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MegaError.malformedResponse }

        if let challenge = http.value(forHTTPHeaderField: "X-Hashcash"), hashcash == nil {
            hashcash = try await Self.solveHashcash(challenge: challenge)
            return nil
        }
        guard http.statusCode == 200 else { throw MegaError.httpStatus(http.statusCode) }
        return data
    }

    static func decode<Response: Decodable>(_ data: Data) throws -> Response {
        let decoder = JSONDecoder()
        if let code = try? decoder.decode(Int.self, from: data), code < 0 {
            throw MegaError.apiCode(code)
        }
        guard let first = try? decoder.decode([Envelope<Response>].self, from: data).first else {
            throw MegaError.malformedResponse
        }
        switch first {
        case .failure(let code): throw MegaError.apiCode(code)
        case .success(let value): return value
        }
    }

    enum Envelope<Value: Decodable>: Decodable {
        case success(Value)
        case failure(Int)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let code = try? container.decode(Int.self), code < 0 {
                self = .failure(code)
            } else {
                self = .success(try container.decode(Value.self))
            }
        }
    }
}

extension APIClient {
    @concurrent
    static func solveHashcash(challenge: String) async throws -> String {
        let parts = challenge.split(separator: ":")
        guard parts.count == 4, parts[0] == "1",
              let easiness = UInt8(parts[1]),
              let token = Base64URL.decode(String(parts[3])), token.count == 48
        else { throw MegaError.proofOfWorkFailed }

        let threshold = (UInt32(easiness & 63) << 1 | 1) << ((UInt32(easiness) >> 6) * 7 + 3)

        var buffer = Data(capacity: 4 + 48 * 262_144)
        buffer.append(Data(count: 4))
        for _ in 0..<262_144 { buffer.append(token) }

        for _ in 0..<(1 << 24) {
            try Task.checkCancellation()
            let digest = SHA256.hash(data: buffer)
            let leading = digest.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            if leading <= threshold {
                return "1:\(parts[3]):\(Base64URL.encode(Data(buffer.prefix(4))))"
            }
            for index in 0..<4 {
                buffer[index] &+= 1
                if buffer[index] != 0 { break }
            }
        }
        throw MegaError.proofOfWorkFailed
    }
}
