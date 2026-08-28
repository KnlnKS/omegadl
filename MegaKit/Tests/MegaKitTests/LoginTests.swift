import BigInt
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
        let masterKey = Data((0..<16).map(UInt8.init))
        var blob = try #require(Base64URL.decode(privkBlob))
        blob.append(Data(count: (16 - blob.count % 16) % 16))
        let wrapped = AES128.ecbEncrypt(blob, key: masterKey)

        let login = LoginResponse(k: "", privk: Base64URL.encode(wrapped), csid: csid, tsid: nil)
        #expect(try MegaLogin.resolveSessionID(login, masterKey: masterKey) == expectedSID)
    }

    @Test func `accepts a self-verifying tsid session`() throws {
        let masterKey = Data((0..<16).map(UInt8.init))
        let challenge = Data((0..<16).map { UInt8($0 &* 5) })
        let tsid = Base64URL.encode(challenge + AES128.ecbEncrypt(challenge, key: masterKey))

        let login = LoginResponse(k: "", privk: nil, csid: nil, tsid: tsid)
        #expect(try MegaLogin.resolveSessionID(login, masterKey: masterKey) == tsid)
    }

    @Test func `rejects a tsid that fails its own check`() {
        let login = LoginResponse(k: "", privk: nil, csid: nil, tsid: Base64URL.encode(Data(count: 32)))
        #expect(throws: MegaError.decryptionFailed) {
            try MegaLogin.resolveSessionID(login, masterKey: Data((0..<16).map(UInt8.init)))
        }
    }
}

@Suite struct LegacyDerivationTests {
    @Test func `derives the v1 password key`() {
        #expect(
            MegaLogin.legacyKey(password: "password123").map { String(format: "%02x", $0) }.joined()
                == "22f683851212b50a92114454fa542b99"
        )
    }

    @Test func `derives the v1 user hash`() {
        let key = MegaLogin.legacyKey(password: "password123")
        #expect(MegaLogin.legacyUserHash(email: "test@example.com", key: key) == "jNU3r7YHrLA")
    }

    @Test func `pads a password shorter than one block`() {
        #expect(MegaLogin.legacyKey(password: "a").count == 16)
        #expect(MegaLogin.legacyKey(password: "").count == 16)
        #expect(MegaLogin.legacyKey(password: "a") != MegaLogin.legacyKey(password: "b"))
    }

    @Test func `spans multiple blocks for a long password`() {
        let long = String(repeating: "correct horse battery staple ", count: 3)
        #expect(MegaLogin.legacyKey(password: long).count == 16)
    }

    @Test func `derives the v2 key and hash from one PBKDF2 output`() {
        let derived = PBKDF2.sha512(
            password: Data("password".utf8), salt: Data("salt".utf8),
            iterations: MegaLogin.derivationIterations, length: 32
        )
        #expect(Data(derived.prefix(16)).count == 16)
        #expect(Base64URL.encode(Data(derived.suffix(16))).count == 22)
        #expect(derived.prefix(16) != derived.suffix(16))
    }
}

@Suite(.serialized) struct KeychainTests {
    private let session = AccountSession(
        sessionID: "test-session", masterKey: Data((0..<16).map(UInt8.init)),
        userHandle: "abcd1234", email: "omegadl-tests@example.invalid"
    )

    @Test func `saves, reloads and removes a session`() throws {
        Keychain.remove(email: session.email)
        try Keychain.save(session)

        let stored = try #require(Keychain.session(email: session.email))
        #expect(stored == session)

        let updated = AccountSession(
            sessionID: "rotated", masterKey: session.masterKey,
            userHandle: session.userHandle, email: session.email
        )
        try Keychain.save(updated)
        #expect(Keychain.session(email: session.email)?.sessionID == "rotated")

        Keychain.remove(email: session.email)
        #expect(Keychain.session(email: session.email) == nil)
    }
}
