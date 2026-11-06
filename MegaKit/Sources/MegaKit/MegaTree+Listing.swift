import CommonCrypto
import Foundation

extension MegaTree {
    private static let h = JSONScanner.code("h"), p = JSONScanner.code("p"), t = JSONScanner.code("t"),
        a = JSONScanner.code("a"), k = JSONScanner.code("k"), s = JSONScanner.code("s"),
        ts = JSONScanner.code("ts"), f = JSONScanner.code("f"), ok = JSONScanner.code("ok"),
        ha = JSONScanner.code("ha"), n = JSONScanner.code("n"), rr = JSONScanner.code("rr")

    /// Builds a tree straight from a files (`f`) or put (`p`) response body, without materializing
    /// intermediate node objects.
    convenience init(listing body: Data, keyring: consuming Keyring) throws {
        let rows = try body.withUnsafeBytes { bytes -> Builder in
            var scanner = JSONScanner(bytes)
            guard scanner.take(UInt8(ascii: "[")), scanner.take(UInt8(ascii: "{")) else { throw MegaError.malformedResponse }

            var nodes: JSONScanner?
            while let key = scanner.key() {
                switch scanner.code(key) {
                case Self.f:
                    nodes = scanner
                    scanner.skipValue()
                case Self.ok:
                    guard scanner.take(UInt8(ascii: "[")) else { throw MegaError.malformedResponse }
                    while scanner.element() { Self.readShare(&scanner, into: &keyring) }
                default:
                    scanner.skipValue()
                }
            }
            guard var nodes, !scanner.failed, nodes.take(UInt8(ascii: "[")) else { throw MegaError.malformedResponse }

            var rows = Builder()
            var scratch = [UInt8]()
            while nodes.element() { Self.readNode(&nodes, keyring: keyring, scratch: &scratch, into: &rows) }
            guard !nodes.failed else { throw MegaError.malformedResponse }
            return rows
        }
        self.init(rows)
    }

    private static func readShare(_ scanner: inout JSONScanner, into keyring: inout Keyring) {
        guard scanner.take(UInt8(ascii: "{")) else { return scanner.skipValue() }
        var handle: NodeHandle?
        var wrapped: AESBlock?
        var authority: AESBlock?
        while let key = scanner.key() {
            switch scanner.code(key) {
            case h: handle = scanner.string().flatMap { NodeHandle(scanner.slice($0)) }
            case k: wrapped = scanner.string().flatMap { Base64URL.decodeBlock(scanner.slice($0)) }
            case ha: authority = scanner.string().flatMap { Base64URL.decodeBlock(scanner.slice($0)) }
            default: scanner.skipValue()
            }
        }
        if let handle, let wrapped { keyring.addShare(handle: handle, wrapped: wrapped, authority: authority) }
    }

    private static func readNode(
        _ scanner: inout JSONScanner, keyring: borrowing Keyring, scratch: inout [UInt8], into rows: inout Builder
    ) {
        guard scanner.take(UInt8(ascii: "{")) else { return scanner.skipValue() }
        var handle: NodeHandle?
        var parent: NodeHandle?
        var type = 0
        var size = 0
        var time = 0
        var attributes: Range<Int>?
        var keyField: Range<Int>?
        while let key = scanner.key() {
            switch scanner.code(key) {
            case h: handle = scanner.string().flatMap { NodeHandle(scanner.slice($0)) }
            case p: parent = scanner.string().flatMap { NodeHandle(scanner.slice($0)) }
            case t: type = scanner.integer() ?? 0
            case s: size = scanner.integer() ?? 0
            case ts: time = scanner.integer() ?? 0
            case a: attributes = scanner.string()
            case k: keyField = scanner.string()
            default: scanner.skipValue()
            }
        }
        guard let handle else { return }

        let kind = MegaNode.Kind(rawValue: type) ?? .file
        var nodeKey: MegaFileKey?
        var decoded: (name: String?, restore: NodeHandle?)?

        // The first key that opens the attributes wins.
        let field = keyField.map(scanner.slice) ?? UnsafeRawBufferPointer(start: nil, count: 0)
        keyring.forEachKey(in: field, isFile: kind == .file) { candidate in
            if nodeKey == nil { nodeKey = candidate }
            guard let attributes, let found = Self.attributes(scanner.slice(attributes), key: candidate.aesKey, scratch: &scratch) else {
                return false
            }
            nodeKey = candidate
            decoded = found
            return true
        }

        rows.append(
            handle: handle, parent: parent, kind: kind, size: size, time: time,
            name: decoded?.name ?? kind.standardName ?? handle.description, key: nodeKey, restore: decoded?.restore
        )
    }

    /// Decrypts a node's attribute blob (`MEGA{json}` under AES-CBC) and reads its name and restore handle.
    static func attributes(
        _ encoded: UnsafeRawBufferPointer, key: AESBlock, scratch: inout [UInt8]
    ) -> (name: String?, restore: NodeHandle?)? {
        let capacity = encoded.count * 3 / 4
        if scratch.count < capacity * 2 { scratch = [UInt8](repeating: 0, count: capacity * 2) }
        return scratch.withUnsafeMutableBytes { buffer -> (String?, NodeHandle?)? in
            let ciphertext = UnsafeMutableRawBufferPointer(rebasing: buffer[..<capacity])
            guard let length = Base64URL.decode(encoded, into: ciphertext), length > 0, length % 16 == 0 else { return nil }
            let plaintext = UnsafeMutableRawBufferPointer(rebasing: buffer[capacity..<(capacity + length)])
            AES.crypt(kCCDecrypt, mode: kCCModeCBC, key: key, UnsafeRawBufferPointer(rebasing: ciphertext[..<length]), into: plaintext.baseAddress!)

            let end = plaintext.firstIndex(of: 0) ?? plaintext.endIndex
            guard plaintext[..<end].starts(with: "MEGA{".utf8) else { return nil }
            var json = JSONScanner(UnsafeRawBufferPointer(rebasing: plaintext[(plaintext.startIndex + 4)..<end]))
            guard json.take(UInt8(ascii: "{")) else { return nil }
            var name: String?
            var restore: NodeHandle?
            while let field = json.key() {
                switch json.code(field) {
                case n: name = json.string().map(json.text)
                case rr: restore = json.string().flatMap { NodeHandle(json.slice($0)) }
                default: json.skipValue()
                }
            }
            return json.failed ? nil : (name, restore)
        }
    }

    static func attributes(_ encoded: String, key: AESBlock) -> (name: String?, restore: NodeHandle?)? {
        var encoded = encoded
        var scratch = [UInt8]()
        return encoded.withUTF8 { attributes(UnsafeRawBufferPointer($0), key: key, scratch: &scratch) }
    }

    static func encodedAttributes(name: String, restoreHandle: NodeHandle? = nil, key: AESBlock) -> String {
        struct Attributes: Encodable {
            let n: String
            let rr: String?
        }
        let json = (try? JSONEncoder().encode(Attributes(n: name, rr: restoreHandle?.description))) ?? Data("{}".utf8)
        var plaintext = Data("MEGA".utf8) + json
        plaintext.append(Data(count: (16 - plaintext.count % 16) % 16))
        return Base64URL.encode(AES.crypt(kCCEncrypt, mode: kCCModeCBC, key: key, plaintext))
    }
}
