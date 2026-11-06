import BigInt
import CommonCrypto
import Foundation
import Testing
@testable import MegaKit

private let privkBlob = """
AgDXWWh4xguaUndFWfKWoO7yOCz2JCKT61pF-bO1gxZIiuD8NwebyttnaCuNwvp8u-zOpBbW1fR7qhrL6WdynIVbAgDw7\
-eSJ3dydYrswhTShs6GMC7aOMIBDesoiAjQxo5xrgQhwrKF3hHCZuT7aEtFaujxqBeV2Vx7b5ZT1figKfGpA_wO-8kYSSI\
uXM4f_AjJLwJ1D5zifT4aTY2Mi8lHES55ZLwC2oxxzXCIrbCISxP8wHdN8hCVlh2wcq21JZuUdFrg5LL8p9mzhWbs_nfKs\
z9CyGA78grHYiZDvhUbzDxwKs_uO0Cp_gmJ3eX5yd5LmoUi14XTBH_V3yEAvCfy0AGn0QIA0fdaBmi0HvpS8N6uUsSb53f\
rA_UVQ4Ejjtdxi-HdWnvY9y1aDKFQ4Df7AGO0fO-N4rfSAOplUraMhSNwB6QF3Q
"""

private let csid = """
BACEDO694R6-m9BKdzeWtr79R1dfDNNN0a-Ef_KkDk_PvRoVrWLS8WTl2fTWRsO1Umo3UttI3G5j9cyGHD2jdInKTKTI8W\
jx5eJZPkl7r3c3xUta3v1UeXa6LqGpf_XdZpfhzyoha-bdgJxg5In9n1qpqwK8cYesCku5R-uhMcGz-w
"""

private let expectedSID = "AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKg"

@Suite struct RSATests {
    @Test func `decodes four MPI components from a private key blob`() throws {
        let blob = try #require(Base64URL.decode(privkBlob))
        let components = try #require(MPI.decode(blob, count: 4))
        #expect(components.count == 4)
        #expect(components[0].bitWidth == 512)
        #expect(components[1].bitWidth == 512)
        #expect(components.allSatisfy { $0 > 1 })
    }

    @Test func `refuses a blob that is too short for its declared bit length`() {
        #expect(MPI.decode(Data([0x08, 0x00]), count: 1) == nil)
        #expect(MPI.decode(Data(), count: 1) == nil)
    }

    @Test func `recovers the plaintext through MEGA's CRT recombination`() throws {
        let blob = try #require(Base64URL.decode(privkBlob))
        let key = try #require(RSAPrivateKey(privkBlob: blob))
        let rawCSID = try #require(Base64URL.decode(csid))
        let ciphertext = try #require(MPI.value(rawCSID))
        let plaintext = key.decrypt(ciphertext)

        #expect(plaintext.count == 60)
        #expect(plaintext.prefix(2) == Data([0x01, 0x01]))
        #expect(Base64URL.encode(Data(plaintext.prefix(43))) == expectedSID)
    }

    @Test func `derives the session id from an encrypted csid`() throws {
        let masterKey = block("000102030405060708090a0b0c0d0e0f")
        var blob = try #require(Base64URL.decode(privkBlob))
        blob.append(Data(count: (16 - blob.count % 16) % 16))
        let wrapped = AES.crypt(kCCEncrypt, mode: kCCModeECB, key: masterKey, blob)

        let login = LoginResponse(k: "", privk: Base64URL.encode(wrapped), csid: csid, tsid: nil)
        #expect(try MegaLogin.resolveSessionID(login, masterKey: masterKey) == expectedSID)
    }

    @Test func `accepts a self-verifying tsid session`() throws {
        let masterKey = block("000102030405060708090a0b0c0d0e0f")
        let challenge = AESBlock((0..<16).map { UInt8($0 &* 5) })
        let tsid = withUnsafeBytes(of: (challenge, AES.encrypt(challenge, key: masterKey)), Base64URL.encode)

        let login = LoginResponse(k: "", privk: nil, csid: nil, tsid: tsid)
        #expect(try MegaLogin.resolveSessionID(login, masterKey: masterKey) == tsid)
    }

    @Test func `rejects a tsid that fails its own check`() {
        let login = LoginResponse(k: "", privk: nil, csid: nil, tsid: Base64URL.encode(Data(count: 32)))
        #expect(throws: MegaError.decryptionFailed) {
            try MegaLogin.resolveSessionID(login, masterKey: block("000102030405060708090a0b0c0d0e0f"))
        }
    }
}

@Suite struct LegacyDerivationTests {
    @Test func `derives the v1 password key`() {
        #expect(MegaLogin.legacyKey(password: "password123") == block("22f683851212b50a92114454fa542b99"))
    }

    @Test func `derives the v1 user hash`() {
        let key = MegaLogin.legacyKey(password: "password123")
        #expect(MegaLogin.legacyUserHash(email: "test@example.com", key: key) == "jNU3r7YHrLA")
    }

    @Test func `derives distinct keys for short and multi-block passwords`() {
        #expect(MegaLogin.legacyKey(password: "") != MegaLogin.legacyKey(password: "a"))
        #expect(MegaLogin.legacyKey(password: "a") != MegaLogin.legacyKey(password: "b"))
        #expect(
            MegaLogin.legacyKey(password: "a password longer than one block")
                != MegaLogin.legacyKey(password: "a password longer than one")
        )
    }
}

@Suite(.serialized) struct KeychainTests {
    private let session = AccountSession(
        sessionID: "test-session", masterKey: block("000102030405060708090a0b0c0d0e0f"),
        userHandle: "abcd1234", email: "omegadl-tests@example.invalid"
    )

    @Test func `saves, reloads and removes a session`() async throws {
        let keychain = Keychain(service: "com.omegadl.tests")
        keychain.remove()
        try keychain.save(session)
        #expect(await keychain.session() == session)

        let updated = AccountSession(
            sessionID: "rotated", masterKey: session.masterKey,
            userHandle: session.userHandle, email: session.email
        )
        try keychain.save(updated)
        #expect(await keychain.session()?.sessionID == "rotated")

        keychain.remove()
        #expect(await keychain.session() == nil)
    }
}

@Suite struct StorageFormatTests {
    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func `stores a session's master key as base64url`() throws {
        let session = AccountSession(sessionID: "sid", masterKey: block("000102030405060708090a0b0c0d0e0f"), userHandle: "abcd1234", email: "a@b.c")
        let stored = #"{"email":"a@b.c","masterKey":"AAECAwQFBgcICQoLDA0ODw","sessionID":"sid","userHandle":"abcd1234"}"#
        #expect(try json(session) == stored)
        #expect(try JSONDecoder().decode(AccountSession.self, from: Data(stored.utf8)) == session)
    }

    @Test func `stores a node handle as its eight characters`() throws {
        let handle = try #require(NodeHandle("LIkEAD7L"))
        #expect(try json([handle]) == #"["LIkEAD7L"]"#)
        #expect(try JSONDecoder().decode([NodeHandle].self, from: Data(#"["LIkEAD7L"]"#.utf8)) == [handle])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([NodeHandle].self, from: Data(#"["short"]"#.utf8)) }
    }
}
