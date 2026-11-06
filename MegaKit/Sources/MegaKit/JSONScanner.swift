import Foundation

/// A forward-only reader over JSON bytes that never allocates while scanning. It trusts structure it
/// skips, treats commas as whitespace, and latches `failed` instead of throwing so loops stay simple.
struct JSONScanner {
    let bytes: UnsafeRawBufferPointer
    private(set) var position = 0
    private(set) var failed = false

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    private mutating func skipSpace() {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","): position += 1
            default: return
            }
        }
    }

    mutating func peek() -> UInt8? {
        skipSpace()
        return position < bytes.count ? bytes[position] : nil
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        position += 1
        return true
    }

    private mutating func fail() -> Bool {
        failed = true
        position = bytes.count
        return false
    }

    /// The raw bytes between the quotes, escapes left in place.
    mutating func string() -> Range<Int>? {
        guard take(UInt8(ascii: "\"")) else { return nil }
        let start = position
        while position < bytes.count {
            switch bytes[position] {
            case UInt8(ascii: "\""):
                position += 1
                return start..<(position - 1)
            case UInt8(ascii: "\\"): position += 2
            default: position += 1
            }
        }
        _ = fail()
        return nil
    }

    mutating func integer() -> Int? {
        guard let first = peek(), first == UInt8(ascii: "-") || (48...57).contains(first) else { return nil }
        let negative = first == UInt8(ascii: "-")
        if negative { position += 1 }
        var value = 0
        while position < bytes.count, case let digit = bytes[position], (48...57).contains(digit) {
            value = value &* 10 &+ Int(digit - 48)
            position += 1
        }
        return negative ? -value : value
    }

    /// Advances to the next member of the object being read, returning its key; nil at the closing brace.
    mutating func key() -> Range<Int>? {
        if take(UInt8(ascii: "}")) || failed { return nil }
        guard let key = string(), take(UInt8(ascii: ":")) else {
            _ = fail()
            return nil
        }
        return key
    }

    /// Advances to the next element of the array being read; false at the closing bracket.
    mutating func element() -> Bool {
        if take(UInt8(ascii: "]")) || failed { return false }
        return peek() != nil || fail()
    }

    mutating func skipValue() {
        switch peek() {
        case UInt8(ascii: "\"")?:
            _ = string()
        case UInt8(ascii: "{")?:
            position += 1
            while key() != nil { skipValue() }
        case UInt8(ascii: "[")?:
            position += 1
            while element() { skipValue() }
        case nil:
            _ = fail()
        default:
            let start = position
            while position < bytes.count, !Self.endsLiteral(bytes[position]) { position += 1 }
            if position == start { _ = fail() }
        }
    }

    private static func endsLiteral(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D: true
        default: false
        }
    }

    func slice(_ range: Range<Int>) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(rebasing: bytes[range])
    }

    /// A key packed into an integer for switching; keys longer than two bytes map to zero.
    func code(_ range: Range<Int>) -> UInt16 {
        switch range.count {
        case 1: UInt16(bytes[range.lowerBound])
        case 2: UInt16(bytes[range.lowerBound]) | UInt16(bytes[range.lowerBound + 1]) << 8
        default: 0
        }
    }

    static func code(_ key: StaticString) -> UInt16 {
        precondition(key.utf8CodeUnitCount <= 2, "keys pack into two bytes")
        return key.withUTF8Buffer { utf8 in utf8.reversed().reduce(0) { $0 << 8 | UInt16($1) } }
    }

    /// Decodes a string's contents. Escapes are rare in MEGA names, so only those strings pay for a full decoder.
    func text(_ range: Range<Int>) -> String {
        let raw = slice(range)
        guard raw.contains(UInt8(ascii: "\\")) else { return String(decoding: raw, as: UTF8.self) }
        let quoted = Data(UnsafeRawBufferPointer(rebasing: bytes[(range.lowerBound - 1)..<(range.upperBound + 1)]))
        return (try? JSONDecoder().decode(String.self, from: quoted)) ?? String(decoding: raw, as: UTF8.self)
    }
}
