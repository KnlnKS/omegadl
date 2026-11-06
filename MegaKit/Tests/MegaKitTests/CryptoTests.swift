import CommonCrypto
import Foundation
import Testing
@testable import MegaKit

@Suite struct Base64URLTests {
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

    @Test func `translates the URL-safe alphabet and accepts the standard one`() throws {
        let data = hex("fbf0")
        #expect(Base64URL.encode(data) == "-_A")
        #expect(try #require(Base64URL.decode("-_A")) == data)
        #expect(try #require(Base64URL.decode("+/A=")) == data)
    }

    @Test(arguments: ["A", "AAAAA", "AB*D", "ünï"]) func `rejects malformed input`(input: String) {
        #expect(Base64URL.decode(input) == nil)
    }

    @Test func `packs a node handle into six bytes and back`() throws {
        let handle = try #require(NodeHandle("LIkEAD7L"))
        #expect(handle.raw >> 48 == 0)
        #expect(handle.description == "LIkEAD7L")
        #expect(NodeHandle("LIkEAD7") == nil)
        #expect(NodeHandle("LIkEAD7L!") == nil)
    }
}

@Suite struct AESTests {
    @Test func `matches the FIPS-197 AES-128 ECB vector`() {
        let key = block("000102030405060708090a0b0c0d0e0f")
        let plaintext = block("00112233445566778899aabbccddeeff")
        let ciphertext = block("69c4e0d86a7b0430d8cdb78070b4c55a")
        #expect(AES.encrypt(plaintext, key: key) == ciphertext)
        #expect(AES.decrypt(ciphertext, key: key) == plaintext)
    }

    @Test func `round-trips CBC with a zero IV`() {
        let key = block("0f0e0d0c0b0a09080706050403020100")
        let plaintext = Data((0..<64).map { UInt8($0 &* 3) })
        let ciphertext = AES.crypt(kCCEncrypt, mode: kCCModeCBC, key: key, plaintext)
        #expect(ciphertext != plaintext)
        #expect(AES.crypt(kCCDecrypt, mode: kCCModeCBC, key: key, ciphertext) == plaintext)
    }

    @Test func `treats empty input as empty output`() {
        #expect(AES.crypt(kCCEncrypt, mode: kCCModeCBC, key: .zero, Data()).isEmpty)
    }
}

@Suite struct CTRTests {
    private let key = MegaFileKey(aesKey: block("000102030405060708090a0b0c0d0e0f"), nonce: half("8ae83362ce78b1e0"), metaMAC: .zero)

    private func ctr(_ data: Data, fromBlock block: Int = 0) -> Data {
        var data = data
        data.withUnsafeMutableBytes {
            Cryptor(kCCEncrypt, mode: kCCModeCTR, key: key.aesKey, iv: key.counter(atBlock: block)).update($0)
        }
        return data
    }

    @Test func `is its own inverse`() {
        let plaintext = Data((0..<1000).map { UInt8($0 & 0xff) })
        let ciphertext = ctr(plaintext)
        #expect(ciphertext != plaintext)
        #expect(ctr(ciphertext) == plaintext)
    }

    @Test(arguments: [1, 16, 64, 8192]) func `seeking matches a from-zero decrypt`(blockOffset: Int) {
        let plaintext = Data((0..<(256 * 1024)).map { UInt8($0 & 0xff) })
        let whole = ctr(plaintext)
        let byteOffset = blockOffset * 16
        #expect(ctr(Data(plaintext[byteOffset...]), fromBlock: blockOffset) == Data(whole[byteOffset...]))
    }

    @Test func `streams across uneven pieces the same as one shot`() {
        let plaintext = Data((0..<5000).map { UInt8($0 & 0xff) })
        let streaming = Cryptor(kCCEncrypt, mode: kCCModeCTR, key: key.aesKey, iv: key.counter(atBlock: 0))
        var pieces = plaintext
        pieces.withUnsafeMutableBytes { buffer in
            for start in stride(from: 0, to: buffer.count, by: 509) {
                streaming.update(UnsafeMutableRawBufferPointer(rebasing: buffer[start..<min(start + 509, buffer.count)]))
            }
        }
        #expect(pieces == ctr(plaintext))
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
}
