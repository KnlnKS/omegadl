import Foundation

/// Base64url straight between UTF-8 and bytes, with no intermediate strings. Decoding also accepts
/// the standard alphabet and stops at padding.
enum Base64URL {
    static func encode(_ bytes: UnsafeRawBufferPointer) -> String {
        let length = (bytes.count * 4 + 2) / 3
        return String(unsafeUninitializedCapacity: length) { out in
            var accumulator: UInt32 = 0
            var bits = 0
            var written = 0
            for byte in bytes {
                accumulator = accumulator << 8 | UInt32(byte)
                bits += 8
                while bits >= 6 {
                    bits -= 6
                    out[written] = symbol(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)) & 63)
                    written += 1
                }
            }
            if bits > 0 {
                out[written] = symbol(UInt8(truncatingIfNeeded: accumulator << UInt32(6 - bits)) & 63)
                written += 1
            }
            return written
        }
    }

    static func encode(_ data: some ContiguousBytes) -> String {
        data.withUnsafeBytes(encode)
    }

    static func encode(_ block: AESBlock) -> String {
        withUnsafeBytes(of: block, encode)
    }

    /// Returns the number of bytes written, or nil for an invalid character or a full `output`.
    static func decode(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Int? {
        var accumulator: UInt32 = 0
        var bits = 0
        var written = 0
        var consumed = 0
        for character in input {
            guard let value = value(of: character) else {
                if character == UInt8(ascii: "=") { break }
                return nil
            }
            consumed += 1
            accumulator = accumulator << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                guard written < output.count else { return nil }
                output[written] = UInt8(truncatingIfNeeded: accumulator >> UInt32(bits))
                written += 1
            }
        }
        return consumed % 4 == 1 ? nil : written
    }

    static func decode(_ string: String) -> Data? {
        var string = string
        return string.withUTF8 { utf8 in
            var data = Data(count: utf8.count * 3 / 4)
            let written = data.withUnsafeMutableBytes { decode(UnsafeRawBufferPointer(utf8), into: $0) }
            guard let written else { return nil }
            data.count = written
            return data
        }
    }

    static func decodeBlock(_ input: UnsafeRawBufferPointer) -> AESBlock? {
        var block = AESBlock()
        let written = withUnsafeMutableBytes(of: &block) { decode(input, into: $0) }
        return written == 16 ? block : nil
    }

    static func decodeBlock(_ string: String) -> AESBlock? {
        var string = string
        return string.withUTF8 { decodeBlock(UnsafeRawBufferPointer($0)) }
    }

    private static func symbol(_ value: UInt8) -> UInt8 {
        switch value {
        case 0..<26: value + 65
        case 26..<52: value + 71
        case 52..<62: value - 4
        case 62: UInt8(ascii: "-")
        default: UInt8(ascii: "_")
        }
    }

    private static func value(of character: UInt8) -> UInt8? {
        switch character {
        case 65...90: character - 65
        case 97...122: character - 71
        case 48...57: character + 4
        case UInt8(ascii: "-"), UInt8(ascii: "+"): 62
        case UInt8(ascii: "_"), UInt8(ascii: "/"): 63
        default: nil
        }
    }
}
