import CommonCrypto
import Foundation
import Testing
@testable import MegaKit

private let realPacked = hex("62b4e6786d5f3a303a7abe9e51cf3ff28ae83362ce78b1e09092af0f70214ec5")
private let realKey = realPacked.withUnsafeBytes { MegaFileKey(packed: $0)! }

private let realPlaintext = hex("""
5b44454641554c545d0d0a4241534555524c3d687474703a2f2f7777772e6e6577616c62756d72656c\
65617365732e6e65742f0d0a5b496e7465726e657453686f72746375745d0d0a55524c3d687474703a\
2f2f7777772e6e6577616c62756d72656c65617365732e6e65742f0d0a
""")

private func syntheticPlaintext(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
}

func chunkMACs(_ plaintext: Data, key: MegaFileKey, chunks: Range<Int>? = nil) -> [AESBlock] {
    let chunks = chunks ?? 0..<Chunking.count(fileSize: plaintext.count)
    return plaintext[Chunking.bytes(of: chunks, fileSize: plaintext.count)].withUnsafeBytes {
        ChunkMAC.compute($0, chunks: chunks, fileSize: plaintext.count, key: key)
    }
}

@Suite struct FileKeyTests {
    @Test func `unpacks a real MEGA node key`() {
        #expect(realKey.aesKey == block("e85cd51aa3278bd0aae8119121ee7137"))
        #expect(realKey.nonce == half("8ae83362ce78b1e0"))
        #expect(realKey.metaMAC == half("9092af0f70214ec5"))
    }

    @Test func `repacking is the exact inverse of unpacking`() {
        #expect(withUnsafeBytes(of: realKey.packed) { Data($0) } == realPacked)
    }

    @Test func `rejects a key that is not 32 bytes`() {
        #expect(Data(count: 16).withUnsafeBytes { MegaFileKey(packed: $0) } == nil)
        #expect(Data(count: 33).withUnsafeBytes { MegaFileKey(packed: $0) } == nil)
    }
}

@Suite struct ChunkingTests {
    @Test func `grows by 128 KB and caps at 1 MB`() {
        let size = 20 * 1_048_576
        let lengths = (0..<Chunking.count(fileSize: size)).map { Chunking.bytes(of: $0, fileSize: size).count }
        #expect(lengths.prefix(8) == [131_072, 262_144, 393_216, 524_288, 655_360, 786_432, 917_504, 1_048_576])
        #expect(lengths.dropFirst(8).dropLast().allSatisfy { $0 == 1_048_576 })
        #expect(lengths.last == 524_288)
    }

    @Test(arguments: [0, 1, 111, 131_071, 131_072, 131_073, 1_500_000, 4_718_592, 4_718_593, 6_610_126])
    func `covers the file exactly on 16-byte boundaries`(size: Int) {
        let ranges = (0..<Chunking.count(fileSize: size)).map { Chunking.bytes(of: $0, fileSize: size) }
        #expect(ranges.reduce(0) { $0 + $1.count } == size)
        #expect(ranges.allSatisfy { !$0.isEmpty && $0.lowerBound % 16 == 0 })
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func `groups whole chunks into segments covering every chunk once`() {
        let size = 30 << 20
        for target in [1 << 20, 2 << 20, 8 << 20] {
            let segments = Array(Chunking.Segments(fileSize: size, targetBytes: target))
            #expect(segments.first?.lowerBound == 0)
            #expect(segments.last?.upperBound == Chunking.count(fileSize: size))
            #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
            #expect(segments.dropLast().allSatisfy { Chunking.bytes(of: $0, fileSize: size).count >= target })
        }
        #expect(Array(Chunking.Segments(fileSize: 111, targetBytes: 2 << 20)) == [0..<1])
        #expect(Array(Chunking.Segments(fileSize: 0, targetBytes: 2 << 20)).isEmpty)
    }
}

@Suite struct ChunkMACTests {
    @Test func `verifies a real single-chunk MEGA file`() {
        #expect(ChunkMAC.condense(chunkMACs(realPlaintext, key: realKey), key: realKey.aesKey) == realKey.metaMAC)
    }

    @Test func `fails verification when a single byte is flipped`() {
        var tampered = realPlaintext
        tampered[40] ^= 0x01
        #expect(ChunkMAC.condense(chunkMACs(tampered, key: realKey), key: realKey.aesKey) != realKey.metaMAC)
    }

    @Test func `matches reference MACs across the growing boundaries`() {
        let key = MegaFileKey(aesKey: block("000102030405060708090a0b0c0d0e0f"), nonce: half("8ae83362ce78b1e0"), metaMAC: .zero)
        let macs = chunkMACs(syntheticPlaintext(1_500_000), key: key)
        #expect(macs.count == 5)
        #expect(macs[0] == block("d1d57d8ba0828fa69afed72a5ca7cf03"))
        #expect(ChunkMAC.condense(macs, key: key.aesKey) == half("923954a965a64e62"))
    }

    @Test(arguments: [1, 111, 131_072, 1_500_000, 2_097_153, 6_610_126])
    func `MACing segment by segment matches MACing the whole file`(size: Int) {
        let plaintext = syntheticPlaintext(size)
        let whole = chunkMACs(plaintext, key: realKey)
        for target in [1 << 20, 2 << 20, 8 << 20] {
            let segmented = Chunking.Segments(fileSize: size, targetBytes: target).flatMap {
                chunkMACs(plaintext, key: realKey, chunks: $0)
            }
            #expect(segmented == whole)
        }
    }

    @Test func `pads a short trailing chunk with zeros`() {
        let short = Data([1, 2, 3])
        #expect(chunkMACs(short, key: realKey) == chunkMACs(short + Data(count: 13), key: realKey))
    }

    @Test func `condenses nothing to zero`() {
        #expect(ChunkMAC.condense([], key: realKey.aesKey) == .zero)
    }
}
