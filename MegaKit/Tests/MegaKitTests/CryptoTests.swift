import Foundation
import Testing
@testable import MegaKit

private func hex(_ string: String) -> Data {
    var bytes = [UInt8]()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return Data(bytes)
}

@Suite struct Base64URLTests {
    @Test func `decodes an unpadded MEGA folder key`() throws {
        let key = try #require(Base64URL.decode("jH6VX0GcTngXCf6kBnQGDA"))
        #expect(key.count == 16)
        #expect(Base64URL.encode(key) == "jH6VX0GcTngXCf6kBnQGDA")
    }

    @Test func `round-trips every length modulo four`() throws {
        for length in 1...20 {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let encoded = Base64URL.encode(data)
            #expect(!encoded.contains("="))
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
            #expect(try #require(Base64URL.decode(encoded)) == data)
        }
    }

    @Test func `translates the URL-safe alphabet`() throws {
        let data = hex("fbf0")
        #expect(Base64URL.encode(data) == "-_A")
        #expect(try #require(Base64URL.decode("-_A")) == data)
    }
}

@Suite struct AESTests {
    @Test func `matches the FIPS-197 AES-128 ECB vector`() {
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let plaintext = hex("00112233445566778899aabbccddeeff")
        let ciphertext = hex("69c4e0d86a7b0430d8cdb78070b4c55a")
        #expect(AES128.ecbEncrypt(plaintext, key: key) == ciphertext)
        #expect(AES128.ecbDecrypt(ciphertext, key: key) == plaintext)
    }

    @Test func `chains ECB across multiple blocks`() {
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let plaintext = Data((0..<48).map(UInt8.init))
        let ciphertext = AES128.ecbEncrypt(plaintext, key: key)
        #expect(ciphertext.count == 48)
        #expect(AES128.ecbDecrypt(ciphertext, key: key) == plaintext)
        #expect(ciphertext.prefix(16) != ciphertext.dropFirst(16).prefix(16))
    }

    @Test func `round-trips CBC with a zero IV`() {
        let key = hex("0f0e0d0c0b0a09080706050403020100")
        let plaintext = Data((0..<64).map { UInt8($0 &* 3) })
        let ciphertext = AES128.cbcEncryptZeroIV(plaintext, key: key)
        #expect(AES128.cbcDecryptZeroIV(ciphertext, key: key) == plaintext)
    }

    @Test func `treats empty input as empty output`() {
        let key = Data(count: 16)
        #expect(AES128.ecbEncrypt(Data(), key: key).isEmpty)
        #expect(AES128.cbcDecryptZeroIV(Data(), key: key).isEmpty)
    }
}

@Suite struct CTRTests {
    private let key = hex("000102030405060708090a0b0c0d0e0f")
    private let nonce = hex("8ae83362ce78b1e0")

    @Test func `is its own inverse`() {
        let plaintext = Data((0..<1000).map { UInt8($0 & 0xff) })
        let ciphertext = CTRCryptor(key: key, nonce: nonce).process(plaintext)
        #expect(ciphertext != plaintext)
        #expect(CTRCryptor(key: key, nonce: nonce).process(ciphertext) == plaintext)
    }

    @Test(arguments: [1, 16, 64, 8192]) func `seeking matches a from-zero decrypt`(blockOffset: UInt64) {
        let plaintext = Data((0..<(256 * 1024)).map { UInt8($0 & 0xff) })
        let whole = CTRCryptor(key: key, nonce: nonce).process(plaintext)

        let byteOffset = Int(blockOffset) * 16
        let tail = Data(plaintext[byteOffset...])
        let seeked = CTRCryptor(key: key, nonce: nonce, blockOffset: blockOffset).process(tail)

        #expect(seeked == Data(whole[byteOffset...]))
    }

    @Test func `streams incrementally the same as one shot`() {
        let plaintext = Data((0..<5000).map { UInt8($0 & 0xff) })
        let oneShot = CTRCryptor(key: key, nonce: nonce).process(plaintext)

        let streaming = CTRCryptor(key: key, nonce: nonce)
        var pieces = Data()
        for chunk in stride(from: 0, to: plaintext.count, by: 512) {
            pieces += streaming.process(Data(plaintext[chunk..<min(chunk + 512, plaintext.count)]))
        }
        #expect(pieces == oneShot)
    }
}

@Suite struct PBKDF2Tests {
    @Test func `matches a reference HMAC-SHA512 vector`() {
        let derived = PBKDF2.sha512(
            password: Data("password".utf8), salt: Data("salt".utf8),
            iterations: 100_000, length: 32
        )
        #expect(derived == hex("f5d17022c96af46c0a1dc49a58bbe654a28e98104883e4af4de974cda2c74122"))
    }

    @Test func `matches a single-iteration 64-byte vector`() {
        let derived = PBKDF2.sha512(
            password: Data("passwd".utf8), salt: Data("salt".utf8),
            iterations: 1, length: 64
        )
        #expect(derived == hex("""
        c74319d99499fc3e9013acff597c23c5baf0a0bec5634c46b8352b793e324723\
        d55caa76b2b25c43402dcfdc06cdcf66f95b7d0429420b39520006749c51a04e
        """))
    }
}
