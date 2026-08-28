import Foundation

struct PartialDownload: Sendable {
    private static let magic = Data("OMDL1".utf8)
    private static let recordSize = 17

    let size: Int
    private(set) var macs: [Data?]

    init(size: Int, chunkCount: Int) {
        self.size = size
        self.macs = Array(repeating: nil, count: chunkCount)
    }

    init?(contentsOf url: URL, size: Int, chunkCount: Int) {
        let header = Self.magic.count + 16
        guard let data = try? Data(contentsOf: url),
              data.count == header + chunkCount * Self.recordSize,
              data.prefix(Self.magic.count) == Self.magic,
              Self.readUInt64(data, at: Self.magic.count) == UInt64(size),
              Self.readUInt64(data, at: Self.magic.count + 8) == UInt64(chunkCount)
        else { return nil }

        self.size = size
        self.macs = (0..<chunkCount).map { index in
            let start = header + index * Self.recordSize
            guard data[start] == 1 else { return nil }
            return Data(data[(start + 1)..<(start + Self.recordSize)])
        }
    }

    var completedChunks: Int { macs.count { $0 != nil } }

    var completedBytes: Int {
        zip(macs, MegaChunking.chunks(fileSize: size)).reduce(0) { $1.0 == nil ? $0 : $0 + $1.1.length }
    }

    mutating func record(_ mac: Data, forChunk index: Int) {
        macs[index] = mac
    }

    func isComplete(chunk index: Int) -> Bool { macs[index] != nil }

    func condensedMAC(key: Data) -> Data? {
        let resolved = macs.compactMap { $0 }
        guard resolved.count == macs.count else { return nil }
        return ChunkMAC.condense(resolved, key: key)
    }

    func write(to url: URL) throws {
        var data = Self.magic
        data.append(Self.uint64(UInt64(size)))
        data.append(Self.uint64(UInt64(macs.count)))
        for mac in macs {
            data.append(mac == nil ? 0 : 1)
            data.append(mac ?? Data(count: 16))
        }
        try data.write(to: url, options: .atomic)
    }

    private static func uint64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
