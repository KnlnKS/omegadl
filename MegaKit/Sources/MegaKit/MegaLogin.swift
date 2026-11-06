import CommonCrypto
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
    let sessionID: String
    let masterKey: AESBlock
    let userHandle: String
    public let email: String
}

/// The master key is stored as base64url, the way MEGA writes keys.
extension AccountSession {
    private enum CodingKeys: String, CodingKey {
        case sessionID, masterKey, userHandle, email
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let masterKey = Base64URL.decodeBlock(try container.decode(String.self, forKey: .masterKey)) else {
            throw DecodingError.dataCorruptedError(forKey: .masterKey, in: container, debugDescription: "Not a 16-byte key")
        }
        self.init(
            sessionID: try container.decode(String.self, forKey: .sessionID), masterKey: masterKey,
            userHandle: try container.decode(String.self, forKey: .userHandle), email: try container.decode(String.self, forKey: .email)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(Base64URL.encode(masterKey), forKey: .masterKey)
        try container.encode(userHandle, forKey: .userHandle)
        try container.encode(email, forKey: .email)
    }
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

    static let legacySeed = AESBlock(
        0x93, 0xC4, 0x67, 0xE3, 0x7D, 0xB0, 0xC7, 0xA4,
        0xD1, 0xBE, 0x3F, 0x81, 0x01, 0x52, 0xCB, 0x56
    )

    @concurrent
    public static func logIn(_ credentials: AccountCredentials) async throws -> AccountSession {
        let api = APIClient()
        let email = credentials.email.lowercased()
        let pre: PreLoginResponse = try await api.request(PreLoginCommand(user: email))

        let passwordKey: AESBlock
        let userHash: String

        if pre.v >= 2 {
            guard let salt = pre.s.flatMap(Base64URL.decode) else { throw MegaError.malformedResponse }
            let derived = PBKDF2.sha512(
                password: Data(credentials.password.utf8), salt: salt,
                iterations: derivationIterations, length: 32
            )
            passwordKey = derived.withUnsafeBytes { AESBlock(UnsafeRawBufferPointer(rebasing: $0.prefix(16)))! }
            userHash = Base64URL.encode(derived.suffix(16))
        } else {
            passwordKey = legacyKey(password: credentials.password)
            userHash = legacyUserHash(email: email, key: passwordKey)
        }

        let login: LoginResponse = try await api.request(
            LoginCommand(user: email, uh: userHash, mfa: credentials.secondFactorCode)
        )

        guard let wrappedMasterKey = Base64URL.decodeBlock(login.k) else { throw MegaError.malformedResponse }
        let masterKey = AES.decrypt(wrappedMasterKey, key: passwordKey)
        let sessionID = try resolveSessionID(login, masterKey: masterKey)

        let user: UserResponse = try await APIClient(.account(sessionID: sessionID)).request(UserCommand())

        return AccountSession(
            sessionID: sessionID, masterKey: masterKey, userHandle: user.u, email: email
        )
    }

    static func resolveSessionID(_ login: LoginResponse, masterKey: AESBlock) throws -> String {
        if let tsid = login.tsid {
            guard let raw = Base64URL.decode(tsid), raw.count >= 32,
                  raw.withUnsafeBytes({
                      AES.encrypt($0.loadUnaligned(as: AESBlock.self), key: masterKey)
                          == $0.loadUnaligned(fromByteOffset: $0.count - 16, as: AESBlock.self)
                  })
            else { throw MegaError.decryptionFailed }
            return tsid
        }

        guard let privk = login.privk.flatMap(Base64URL.decode), privk.count % 16 == 0,
              let csid = login.csid.flatMap(Base64URL.decode),
              let key = RSAPrivateKey(privkBlob: AES.crypt(kCCDecrypt, mode: kCCModeECB, key: masterKey, privk)),
              let ciphertext = MPI.value(csid)
        else { throw MegaError.decryptionFailed }

        return Base64URL.encode(key.decrypt(ciphertext).prefix(43))
    }

    static func legacyKey(password: String) -> AESBlock {
        let bytes = Array(password.utf8)
        let blocks = stride(from: 0, to: max(bytes.count, 1), by: 16).map { start in
            var block = AESBlock()
            for (index, byte) in bytes[start..<min(start + 16, bytes.count)].enumerated() { block[index] = byte }
            return block
        }

        var key = legacySeed
        for _ in 0..<legacyKeyRounds {
            for block in blocks {
                key = AES.encrypt(key, key: block)
            }
        }
        return key
    }

    static func legacyUserHash(email: String, key: AESBlock) -> String {
        var hash = AESBlock()
        for (index, byte) in email.utf8.enumerated() { hash[index % 16] ^= byte }

        let ecb = Cryptor(kCCEncrypt, mode: kCCModeECB, key: key)
        for _ in 0..<legacyHashRounds { hash = ecb(hash) }
        return withUnsafeBytes(of: SIMD8(lowHalf: hash.lowHalf.lowHalf, highHalf: hash.highHalf.lowHalf), Base64URL.encode)
    }
}
