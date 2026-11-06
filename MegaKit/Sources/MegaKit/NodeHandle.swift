/// A MEGA node handle: eight base64url characters packed as their six raw bytes.
public struct NodeHandle: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let raw: UInt64

    init(raw: UInt64) {
        self.raw = raw
    }

    init?(_ utf8: UnsafeRawBufferPointer) {
        guard utf8.count == 8 else { return nil }
        var raw: UInt64 = 0
        guard withUnsafeMutableBytes(of: &raw, { Base64URL.decode(utf8, into: $0) }) == 6 else { return nil }
        self.raw = raw
    }

    public init?(_ string: String) {
        var string = string
        guard let handle = string.withUTF8({ NodeHandle(UnsafeRawBufferPointer($0)) }) else { return nil }
        self = handle
    }

    public var description: String {
        withUnsafeBytes(of: raw) { Base64URL.encode(UnsafeRawBufferPointer(rebasing: $0.prefix(6))) }
    }

    public static func < (lhs: NodeHandle, rhs: NodeHandle) -> Bool { lhs.raw < rhs.raw }

    /// Encoded as MEGA writes it, so the format does not depend on the packing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let handle = NodeHandle(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a node handle")
        }
        self = handle
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
