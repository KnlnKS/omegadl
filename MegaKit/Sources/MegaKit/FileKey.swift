import Foundation

public struct MegaFileKey: Sendable, Equatable {
    public let aesKey: Data
    public let nonce: Data
    public let metaMAC: Data

    public init?(packed: Data) {
        guard packed.count == 32 else { return nil }
        let head = Data(packed.prefix(16))
        let tail = Data(packed.suffix(16))
        self.aesKey = head.xor(tail)
        self.nonce = Data(tail.prefix(8))
        self.metaMAC = Data(tail.suffix(8))
    }

    public init(aesKey: Data, nonce: Data, metaMAC: Data) {
        precondition(aesKey.count == 16 && nonce.count == 8 && metaMAC.count == 8)
        self.aesKey = aesKey
        self.nonce = nonce
        self.metaMAC = metaMAC
    }

    public var packed: Data {
        let tail = nonce + metaMAC
        return aesKey.xor(tail) + tail
    }
}
