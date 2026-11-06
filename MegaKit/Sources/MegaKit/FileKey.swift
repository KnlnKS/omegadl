import Foundation

/// A file's AES key, CTR nonce and condensed MAC: 32 bytes inline, no heap storage.
public struct MegaFileKey: Sendable, Hashable {
    public let aesKey: AESBlock
    public let nonce: SIMD8<UInt8>
    public let metaMAC: SIMD8<UInt8>

    public init(aesKey: AESBlock, nonce: SIMD8<UInt8>, metaMAC: SIMD8<UInt8>) {
        self.aesKey = aesKey
        self.nonce = nonce
        self.metaMAC = metaMAC
    }

    /// MEGA ships the key as `aesKey ^ tail` followed by `tail`, where `tail` is nonce then MAC.
    init(head: AESBlock, tail: AESBlock) {
        self.init(aesKey: head ^ tail, nonce: tail.lowHalf, metaMAC: tail.highHalf)
    }

    init?(packed bytes: UnsafeRawBufferPointer) {
        guard bytes.count == 32 else { return nil }
        self.init(head: bytes.loadUnaligned(as: AESBlock.self), tail: bytes.loadUnaligned(fromByteOffset: 16, as: AESBlock.self))
    }

    var tail: AESBlock { AESBlock(lowHalf: nonce, highHalf: metaMAC) }

    var packed: (head: AESBlock, tail: AESBlock) { (aesKey ^ tail, tail) }

    /// Chunk MACs run CBC with the nonce repeated as the IV.
    var macIV: AESBlock { AESBlock(lowHalf: nonce, highHalf: nonce) }

    func counter(atBlock block: Int) -> AESBlock {
        AESBlock(lowHalf: nonce, highHalf: unsafeBitCast(UInt64(block).bigEndian, to: SIMD8<UInt8>.self))
    }
}
