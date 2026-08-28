import Foundation
import Testing
@testable import MegaKit

@Suite struct AttributeEncodingTests {
    private let key = Data((0..<16).map(UInt8.init))

    @Test(arguments: [
        "photo.jpg", "06 - Hoops.mp3", "a", "Ünïcödé — ναμε 🎧.txt",
        "a name long enough to spill past a single sixteen byte block.bin",
    ]) func `round-trips a name through MEGA's attribute blob`(name: String) {
        let encoded = NodeDecryptor.encodedAttributes(name: name, key: key)
        #expect(NodeDecryptor.name(from: encoded, key: key) == name)
    }

    @Test func `pads the attribute blob to whole AES blocks`() throws {
        let encoded = NodeDecryptor.encodedAttributes(name: "x.txt", key: key)
        let raw = try #require(Base64URL.decode(encoded))
        #expect(raw.count % 16 == 0)
        #expect(!raw.isEmpty)
    }

    @Test func `yields nothing when decrypted with the wrong key`() {
        let encoded = NodeDecryptor.encodedAttributes(name: "secret.txt", key: key)
        #expect(NodeDecryptor.name(from: encoded, key: Data(count: 16)) == nil)
    }
}

@Suite struct UploadTokenTests {
    @Test func `passes through a textual completion token`() throws {
        let body = Data("hV8kQ2-abc_XYZ".utf8)
        #expect(try UploadEngine.token(from: body) == "hV8kQ2-abc_XYZ")
    }

    @Test func `base64url-encodes a binary completion token`() throws {
        let body = Data([0x00, 0xFF, 0x10, 0x80, 0x7F, 0x01])
        #expect(try UploadEngine.token(from: body) == Base64URL.encode(body))
    }

    @Test func `rejects an empty completion token`() {
        #expect(throws: MegaError.malformedResponse) { try UploadEngine.token(from: Data()) }
    }
}

@Suite struct UploadRoundTripTests {
    private func syntheticPlaintext(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    @Test(arguments: [0, 1, 111, 131_072, 1_500_000])
    func `an uploaded file decrypts and verifies through the download path`(size: Int) throws {
        let masterKey = Data((0..<16).map { UInt8(255 - $0) })
        let plaintext = syntheticPlaintext(size)

        let key = Data.random(count: 16)
        let nonce = Data.random(count: 8)

        let chunks = MegaChunking.chunks(fileSize: size)
        let macs = chunks.map {
            ChunkMAC.mac(forChunk: Data(plaintext[$0.range]), key: key, nonce: nonce)
        }
        let uploaded = MegaFileKey(aesKey: key, nonce: nonce, metaMAC: ChunkMAC.condense(macs, key: key))
        let ciphertext = CTRCryptor(key: key, nonce: nonce).process(plaintext)

        let wireKey = AES128.ecbEncrypt(uploaded.packed, key: masterKey)
        let recovered = try #require(MegaFileKey(packed: AES128.ecbDecrypt(wireKey, key: masterKey)))
        #expect(recovered == uploaded)

        let decrypted = CTRCryptor(key: recovered.aesKey, nonce: recovered.nonce).process(ciphertext)
        #expect(decrypted == plaintext)

        let verified = MegaChunking.chunks(fileSize: size).map {
            ChunkMAC.mac(forChunk: Data(decrypted[$0.range]), key: recovered.aesKey, nonce: recovered.nonce)
        }
        #expect(ChunkMAC.condense(verified, key: recovered.aesKey) == recovered.metaMAC)
    }

    @Test func `a tampered upload fails the receiver's integrity check`() throws {
        let plaintext = syntheticPlaintext(400_000)
        let key = Data.random(count: 16)
        let nonce = Data.random(count: 8)

        let chunks = MegaChunking.chunks(fileSize: plaintext.count)
        let macs = chunks.map { ChunkMAC.mac(forChunk: Data(plaintext[$0.range]), key: key, nonce: nonce) }
        let uploaded = MegaFileKey(aesKey: key, nonce: nonce, metaMAC: ChunkMAC.condense(macs, key: key))

        var ciphertext = CTRCryptor(key: key, nonce: nonce).process(plaintext)
        ciphertext[200_000] ^= 0x40

        let decrypted = CTRCryptor(key: key, nonce: nonce).process(ciphertext)
        let recomputed = chunks.map { ChunkMAC.mac(forChunk: Data(decrypted[$0.range]), key: key, nonce: nonce) }
        #expect(ChunkMAC.condense(recomputed, key: key) != uploaded.metaMAC)
    }

    @Test func `generates distinct random keys`() {
        let keys = (0..<32).map { _ in Data.random(count: 16) }
        #expect(Set(keys).count == 32)
        #expect(keys.allSatisfy { $0.count == 16 })
    }
}
