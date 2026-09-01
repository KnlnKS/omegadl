import Foundation

public struct MegaChunk: Sendable, Equatable {
    public let offset: Int
    public let length: Int

    public var range: Range<Int> { offset..<(offset + length) }
}

public enum MegaChunking {
    public static let firstChunkSize = 131_072
    public static let maximumChunkSize = 1_048_576

    public static func chunks(fileSize: Int) -> [MegaChunk] {
        var chunks = [MegaChunk]()
        var offset = 0
        var size = 0
        while offset < fileSize {
            size = min(size + firstChunkSize, maximumChunkSize)
            let length = min(size, fileSize - offset)
            chunks.append(MegaChunk(offset: offset, length: length))
            offset += length
        }
        return chunks
    }

    public static func segments(chunks: [MegaChunk], targetBytes: Int) -> [Range<Int>] {
        var segments = [Range<Int>]()
        var start = 0
        var bytes = 0
        for (index, chunk) in chunks.enumerated() {
            bytes += chunk.length
            if bytes >= targetBytes || index == chunks.count - 1 {
                segments.append(start..<(index + 1))
                start = index + 1
                bytes = 0
            }
        }
        return segments
    }
}

public enum ChunkMAC {
    public static func mac(forChunk plaintext: Data, key: Data, nonce: Data) -> Data {
        precondition(nonce.count == 8)
        var padded = plaintext
        padded.append(Data(count: (16 - plaintext.count % 16) % 16))
        guard !padded.isEmpty else { return nonce + nonce }
        return Data(AES128.cbcEncrypt(padded, key: key, iv: nonce + nonce).suffix(16))
    }

    public static func condense(_ macs: [Data], key: Data) -> Data {
        guard !macs.isEmpty else { return Data(count: 8) }
        let folded = Data(AES128.cbcEncrypt(macs.reduce(Data(), +), key: key).suffix(16))
        return Data(folded.prefix(4)).xor(Data(folded[4..<8]))
            + Data(folded[8..<12]).xor(Data(folded.suffix(4)))
    }
}
