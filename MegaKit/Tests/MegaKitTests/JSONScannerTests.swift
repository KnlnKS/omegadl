import Testing
@testable import MegaKit

private func scan<Result>(_ json: String, _ body: (inout JSONScanner) -> Result) -> Result {
    var json = json
    return json.withUTF8 { utf8 in
        var scanner = JSONScanner(UnsafeRawBufferPointer(utf8))
        return body(&scanner)
    }
}

@Suite struct JSONScannerTests {
    @Test func `reads the members it asks for and skips the rest`() {
        let read = scan(#"{"x":{"y":[1,{"z":"]}"}],"w":true},"n":"a\"b","s":-42}"#) { scanner in
            var name: String?
            var size: Int?
            _ = scanner.take(UInt8(ascii: "{"))
            while let key = scanner.key() {
                switch scanner.code(key) {
                case JSONScanner.code("n"): name = scanner.string().map(scanner.text)
                case JSONScanner.code("s"): size = scanner.integer()
                default: scanner.skipValue()
                }
            }
            return (name, size, scanner.failed)
        }
        #expect(read.0 == "a\"b" && read.1 == -42 && !read.2)
    }

    @Test(arguments: [#"{"n":"abc"#, #"{"n":"abc\"#, #"{"n":}"#, #"{"n"}"#, #"{"n":"#, "[1,2", #"{"n":[1,{"#, ""])
    func `latches failure on truncated or malformed input`(json: String) {
        #expect(scan(json) { scanner in
            scanner.skipValue()
            return scanner.failed
        })
    }
}
