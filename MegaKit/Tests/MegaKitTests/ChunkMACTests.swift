import Foundation
import Testing
@testable import MegaKit

private let realKey = MegaFileKey(packed: hex(
    "62b4e6786d5f3a303a7abe9e51cf3ff28ae83362ce78b1e09092af0f70214ec5"
))!

private let realPlaintext = hex("""
5b44454641554c545d0d0a4241534555524c3d687474703a2f2f7777772e6e6577616c62756d72656c\
65617365732e6e65742f0d0a5b496e7465726e657453686f72746375745d0d0a55524c3d687474703a\
2f2f7777772e6e6577616c62756d72656c65617365732e6e65742f0d0a
""")

private func syntheticPlaintext(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
}

@Suite struct FileKeyTests {
    @Test func `unpacks a real MEGA node key`() {
        #expect(realKey.aesKey == hex("e85cd51aa3278bd0aae8119121ee7137"))
        #expect(realKey.nonce == hex("8ae83362ce78b1e0"))
        #expect(realKey.metaMAC == hex("9092af0f70214ec5"))
    }

    @Test func `repacking is the exact inverse of unpacking`() {
        #expect(realKey.packed == hex("62b4e6786d5f3a303a7abe9e51cf3ff28ae83362ce78b1e09092af0f70214ec5"))
        #expect(MegaFileKey(packed: realKey.packed) == realKey)
    }

    @Test func `rejects a key that is not 32 bytes`() {
        #expect(MegaFileKey(packed: Data(count: 16)) == nil)
        #expect(MegaFileKey(packed: Data(count: 33)) == nil)
    }
}

@Suite struct ChunkingTests {
    @Test func `grows by 128 KB and caps at 1 MB`() {
        let chunks = MegaChunking.chunks(fileSize: 20 * 1_048_576)
        #expect(chunks.prefix(8).map(\.length) == [
            131_072, 262_144, 393_216, 524_288, 655_360, 786_432, 917_504, 1_048_576
        ])
        #expect(chunks.dropFirst(8).dropLast().allSatisfy { $0.length == 1_048_576 })
        #expect(chunks.last?.length == 524_288)
    }

    @Test func `covers the file exactly with no gaps`() {
        for size in [0, 1, 111, 131_071, 131_072, 131_073, 1_500_000, 6_610_126] {
            let chunks = MegaChunking.chunks(fileSize: size)
            #expect(chunks.reduce(0) { $0 + $1.length } == size)
            #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.offset + $0.length == $1.offset })
            #expect(chunks.first?.offset ?? 0 == 0)
        }
    }

    @Test func `starts every chunk on a 16-byte boundary so CTR can seek`() {
        for chunk in MegaChunking.chunks(fileSize: 6_610_126) {
            #expect(chunk.offset % 16 == 0)
        }
    }

    @Test func `treats an empty file as having no chunks`() {
        #expect(MegaChunking.chunks(fileSize: 0).isEmpty)
    }
}

@Suite struct ChunkMACTests {
    @Test func `verifies a real single-chunk MEGA file`() {
        let mac = ChunkMAC.mac(forChunk: realPlaintext, key: realKey.aesKey, nonce: realKey.nonce)
        #expect(ChunkMAC.condense([mac], key: realKey.aesKey) == realKey.metaMAC)
    }

    @Test func `fails verification when a single byte is flipped`() {
        var tampered = realPlaintext
        tampered[40] ^= 0x01
        let mac = ChunkMAC.mac(forChunk: tampered, key: realKey.aesKey, nonce: realKey.nonce)
        #expect(ChunkMAC.condense([mac], key: realKey.aesKey) != realKey.metaMAC)
    }

    @Test func `verifies a multi-chunk file across the growing boundaries`() {
        let key = Data((0..<16).map(UInt8.init))
        let nonce = hex("8ae83362ce78b1e0")
        let plaintext = syntheticPlaintext(1_500_000)
        let chunks = MegaChunking.chunks(fileSize: plaintext.count)
        #expect(chunks.count == 5)

        let macs = chunks.map {
            ChunkMAC.mac(forChunk: Data(plaintext[$0.range]), key: key, nonce: nonce)
        }
        #expect(macs[0] == hex("d1d57d8ba0828fa69afed72a5ca7cf03"))
        #expect(ChunkMAC.condense(macs, key: key) == hex("923954a965a64e62"))
    }

    @Test func `computes chunk MACs independently of their neighbours`() {
        let key = Data((0..<16).map(UInt8.init))
        let nonce = hex("8ae83362ce78b1e0")
        let plaintext = syntheticPlaintext(1_500_000)
        let chunks = MegaChunking.chunks(fileSize: plaintext.count)

        let inOrder = chunks.map {
            ChunkMAC.mac(forChunk: Data(plaintext[$0.range]), key: key, nonce: nonce)
        }
        let reversed = chunks.reversed().map {
            ChunkMAC.mac(forChunk: Data(plaintext[$0.range]), key: key, nonce: nonce)
        }
        #expect(Array(reversed.reversed()) == inOrder)
    }

    @Test func `pads a short trailing chunk with zeros`() {
        let key = Data(count: 16)
        let nonce = Data(count: 8)
        let short = Data([1, 2, 3])
        #expect(ChunkMAC.mac(forChunk: short, key: key, nonce: nonce)
                == ChunkMAC.mac(forChunk: short + Data(count: 13), key: key, nonce: nonce))
    }
}
