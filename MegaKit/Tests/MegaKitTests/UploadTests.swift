import CommonCrypto
import Foundation
import Testing
@testable import MegaKit

@Suite struct AttributeEncodingTests {
    private let key = block("000102030405060708090a0b0c0d0e0f")

    @Test(arguments: [
        "photo.jpg", "06 - Hoops.mp3", "a", "Ünïcödé — ναμε 🎧.txt", #"AC/DC "live" \ tab\t.flac"#,
        "a name long enough to spill past a single sixteen byte block.bin",
    ]) func `round-trips a name through MEGA's attribute blob`(name: String) {
        #expect(MegaTree.attributes(MegaTree.encodedAttributes(name: name, key: key), key: key)?.name == name)
    }

    @Test func `round-trips a restore handle`() {
        let origin = NodeHandle("AbCdEfGh")!
        #expect(MegaTree.attributes(MegaTree.encodedAttributes(name: "x", restoreHandle: origin, key: key), key: key)?.restore == origin)
    }

    @Test func `reads surrogate-pair escapes and skips unrelated fields`() throws {
        var plaintext = Data(#"MEGA{"c":{"x":[1,2]},"n":"\ud83c\udfa7 \u00fc","e":true}"#.utf8)
        plaintext.append(Data(count: (16 - plaintext.count % 16) % 16))
        let encoded = Base64URL.encode(AES.crypt(kCCEncrypt, mode: kCCModeCBC, key: key, plaintext))
        #expect(MegaTree.attributes(encoded, key: key)?.name == "🎧 ü")
    }

    @Test func `yields nothing when decrypted with the wrong key`() {
        #expect(MegaTree.attributes(MegaTree.encodedAttributes(name: "secret.txt", key: key), key: .zero) == nil)
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
    @Test(arguments: [1, 111, 131_072, 1_500_000])
    func `an uploaded file decrypts and verifies through the download path`(size: Int) throws {
        let masterKey = block("fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0")
        let plaintext = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let draft = MegaFileKey(aesKey: .random(), nonce: AESBlock.random().lowHalf, metaMAC: .zero)
        let uploaded = MegaFileKey(
            aesKey: draft.aesKey, nonce: draft.nonce,
            metaMAC: ChunkMAC.condense(chunkMACs(plaintext, key: draft), key: draft.aesKey)
        )

        let packed = uploaded.packed
        let wire = (AES.encrypt(packed.head, key: masterKey), AES.encrypt(packed.tail, key: masterKey))
        let recovered = MegaFileKey(head: AES.decrypt(wire.0, key: masterKey), tail: AES.decrypt(wire.1, key: masterKey))
        #expect(recovered == uploaded)
        #expect(ChunkMAC.condense(chunkMACs(plaintext, key: recovered), key: recovered.aesKey) == recovered.metaMAC)
    }
}
