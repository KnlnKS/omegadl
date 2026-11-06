import CommonCrypto
import Foundation

/// MEGA MACs files in chunks that grow by 128 KB up to 1 MB. The layout is closed-form, so nothing is stored.
enum Chunking {
    static let step = 131_072
    static let maximum = 1_048_576
    private static let rampCount = maximum / step
    private static let rampBytes = step * rampCount * (rampCount + 1) / 2

    static func offset(of chunk: Int) -> Int {
        chunk < rampCount ? step * chunk * (chunk + 1) / 2 : rampBytes + (chunk - rampCount) * maximum
    }

    static func count(fileSize: Int) -> Int {
        if fileSize > rampBytes { return rampCount + (fileSize - rampBytes + maximum - 1) / maximum }
        var chunk = 0
        while offset(of: chunk) < fileSize { chunk += 1 }
        return chunk
    }

    static func bytes(of chunks: Range<Int>, fileSize: Int) -> Range<Int> {
        offset(of: chunks.lowerBound)..<min(offset(of: chunks.upperBound), fileSize)
    }

    static func bytes(of chunk: Int, fileSize: Int) -> Range<Int> {
        bytes(of: chunk..<(chunk + 1), fileSize: fileSize)
    }

    /// Runs of whole chunks, each at least `targetBytes` long except the last.
    struct Segments: Sequence, IteratorProtocol {
        let count: Int
        let targetBytes: Int
        var chunk = 0

        init(fileSize: Int, targetBytes: Int) {
            self.count = Chunking.count(fileSize: fileSize)
            self.targetBytes = targetBytes
        }

        mutating func next() -> Range<Int>? {
            guard chunk < count else { return nil }
            let start = chunk
            let startOffset = Chunking.offset(of: start)
            repeat { chunk += 1 } while chunk < count && Chunking.offset(of: chunk) - startOffset < targetBytes
            return start..<chunk
        }
    }
}

enum ChunkMAC {
    private static let stripe = 16_384

    /// CBC-MACs every chunk in `chunks`, whose plaintext starts at the first chunk's offset.
    static func compute(_ plaintext: UnsafeRawBufferPointer, chunks: Range<Int>, fileSize: Int, key: MegaFileKey) -> [AESBlock] {
        let cbc = Cryptor(kCCEncrypt, mode: kCCModeCBC, key: key.aesKey)
        let base = Chunking.offset(of: chunks.lowerBound)
        return withUnsafeTemporaryAllocation(byteCount: stripe, alignment: 16) { scratch in
            chunks.map { chunk in
                let range = Chunking.bytes(of: chunk, fileSize: fileSize)
                var position = range.lowerBound - base
                let end = range.upperBound - base
                let whole = position + ((end - position) & ~15)
                var last = AESBlock()
                cbc.reset(iv: key.macIV)
                while position < whole {
                    let count = min(stripe, whole - position)
                    cbc.update(plaintext.baseAddress! + position, into: scratch.baseAddress!, count: count)
                    last = scratch.loadUnaligned(fromByteOffset: count - 16, as: AESBlock.self)
                    position += count
                }
                if whole < end {
                    var tail = AESBlock()
                    withUnsafeMutableBytes(of: &tail) {
                        $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: plaintext[whole..<end]))
                    }
                    last = cbc(tail)
                }
                return last
            }
        }
    }

    static func condense(_ macs: some Sequence<AESBlock>, key: AESBlock) -> SIMD8<UInt8> {
        let cbc = Cryptor(kCCEncrypt, mode: kCCModeCBC, key: key)
        var last: AESBlock?
        for mac in macs { last = cbc(mac) }
        return last?.condensed ?? .zero
    }
}
