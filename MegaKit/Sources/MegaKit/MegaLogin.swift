import Foundation

public struct AccountCredentials: Sendable {
    public let email: String
    public let password: String
    public let secondFactorCode: String?

    public init(email: String, password: String, secondFactorCode: String? = nil) {
        self.email = email
        self.password = password
        self.secondFactorCode = secondFactorCode
    }
}

public struct AccountSession: Sendable, Codable, Hashable {
    public let sessionID: String
    public let masterKey: Data
    public let userHandle: String
    public let email: String
}

struct PreLoginCommand: Encodable, Sendable {
    let a = "us0"
    let user: String
}

struct PreLoginResponse: Decodable, Sendable {
    let v: Int
    let s: String?
}

struct LoginCommand: Encodable, Sendable {
    let a = "us"
    let user: String
    let uh: String
    let mfa: String?
}

struct LoginResponse: Decodable, Sendable {
    let k: String
    let privk: String?
    let csid: String?
    let tsid: String?
}

struct UserCommand: Encodable, Sendable {
    let a = "ug"
}

struct UserResponse: Decodable, Sendable {
    let u: String
}

public enum MegaLogin {
    static let legacyKeyRounds = 65_536
    static let legacyHashRounds = 16_384
    static let derivationIterations = 100_000

    static let legacySeed = Data([
        0x93, 0xC4, 0x67, 0xE3, 0x7D, 0xB0, 0xC7, 0xA4,
        0xD1, 0xBE, 0x3F, 0x81, 0x01, 0x52, 0xCB, 0x56,
    ])

    @concurrent
    public static func logIn(_ credentials: AccountCredentials, api: APIClient) async throws -> AccountSession {
        let email = credentials.email.lowercased()
        let pre: PreLoginResponse = try await api.request(PreLoginCommand(user: email))

        let passwordKey: Data
        let userHash: String

        if pre.v >= 2 {
            guard let salt = pre.s.flatMap(Base64URL.decode) else { throw MegaError.malformedResponse }
            let derived = PBKDF2.sha512(
                password: Data(credentials.password.utf8), salt: salt,
                iterations: derivationIterations, length: 32
            )
            passwordKey = Data(derived.prefix(16))
            userHash = Base64URL.encode(Data(derived.suffix(16)))
        } else {
            passwordKey = legacyKey(password: credentials.password)
            userHash = legacyUserHash(email: email, key: passwordKey)
        }

        let login: LoginResponse = try await api.request(
            LoginCommand(user: email, uh: userHash, mfa: credentials.secondFactorCode)
        )

        guard let wrappedMasterKey = Base64URL.decode(login.k), wrappedMasterKey.count == 16 else {
            throw MegaError.malformedResponse
        }
        let masterKey = AES128.ecbDecrypt(wrappedMasterKey, key: passwordKey)
        let sessionID = try resolveSessionID(login, masterKey: masterKey)

        await api.setSessionID(sessionID)
        let user: UserResponse = try await api.request(UserCommand())

        return AccountSession(
            sessionID: sessionID, masterKey: masterKey, userHandle: user.u, email: email
        )
    }

    static func resolveSessionID(_ login: LoginResponse, masterKey: Data) throws -> String {
        if let tsid = login.tsid {
            guard let raw = Base64URL.decode(tsid), raw.count >= 32,
                  AES128.ecbEncrypt(Data(raw.prefix(16)), key: masterKey) == Data(raw.suffix(16))
            else { throw MegaError.decryptionFailed }
            return tsid
        }

        guard let privk = login.privk.flatMap(Base64URL.decode), privk.count % 16 == 0,
              let csid = login.csid.flatMap(Base64URL.decode),
              let key = RSAPrivateKey(privkBlob: AES128.ecbDecrypt(privk, key: masterKey)),
              let ciphertext = MPI.value(csid)
        else { throw MegaError.decryptionFailed }

        return Base64URL.encode(Data(key.decrypt(ciphertext).prefix(43)))
    }

    static func legacyKey(password: String) -> Data {
        let bytes = Data(password.utf8)
        let blocks = stride(from: 0, to: max(bytes.count, 1), by: 16).map { start -> Data in
            var block = Data(bytes[start..<min(start + 16, bytes.count)])
            block.append(Data(count: 16 - block.count))
            return block
        }

        var key = legacySeed
        for _ in 0..<legacyKeyRounds {
            for block in blocks {
                key = AES128.ecbEncrypt(key, key: block)
            }
        }
        return key
    }

    static func legacyUserHash(email: String, key: Data) -> String {
        let bytes = Data(email.utf8)
        var hash = Data(count: 16)

        for offset in stride(from: 0, to: bytes.count, by: 4) {
            var word = Data(bytes[offset..<min(offset + 4, bytes.count)])
            word.append(Data(count: 4 - word.count))
            let slot = (offset / 4) % 4
            for index in 0..<4 {
                hash[slot * 4 + index] ^= word[index]
            }
        }

        for _ in 0..<legacyHashRounds {
            hash = AES128.ecbEncrypt(hash, key: key)
        }
        return Base64URL.encode(Data(hash.prefix(4)) + Data(hash[8..<12]))
    }
}
