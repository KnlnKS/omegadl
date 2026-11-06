import Foundation
import Testing
@testable import MegaKit

private extension MegaLink {
    var folderKey: AESBlock? {
        if case .folder(let key) = kind { key } else { nil }
    }

    var fileKey: MegaFileKey? {
        if case .file(let key) = kind { key } else { nil }
    }
}

private let folderHandle = NodeHandle(Live.folderID)!
private let fileKey = Base64URL.encode(Data((0..<32).map(UInt8.init)))

@Suite struct MegaLinkTests {
    @Test func `parses the current folder format`() throws {
        let link = try #require(MegaLink(Live.folderURL))
        #expect(link.handle == folderHandle)
        #expect(link.folderKey.map(Base64URL.encode) == Live.folderKey)
        #expect(link.selectedHandle == nil)
    }

    @Test func `parses a file selected inside a folder`() throws {
        let link = try #require(MegaLink("\(Live.folderURL)/file/\(Live.smallFileHandle)"))
        #expect(link.folderKey != nil)
        #expect(link.handle == folderHandle)
        #expect(link.selectedHandle == NodeHandle(Live.smallFileHandle))
    }

    @Test func `parses a subfolder path in the fragment`() throws {
        let link = try #require(MegaLink("\(Live.folderURL)/folder/AbCdEfGh"))
        #expect(link.folderKey != nil)
        #expect(link.selectedHandle == NodeHandle("AbCdEfGh"))
    }

    @Test func `parses the current file format`() throws {
        let link = try #require(MegaLink("https://mega.nz/file/AbCdEfGh#\(fileKey)"))
        #expect(link.handle == NodeHandle("AbCdEfGh"))
        #expect(link.fileKey.map { withUnsafeBytes(of: $0.packed, Base64URL.encode) } == fileKey)
    }

    @Test func `parses the legacy folder format`() throws {
        let link = try #require(MegaLink("https://mega.nz/#F!\(Live.folderID)!\(Live.folderKey)"))
        #expect(link.handle == folderHandle)
        #expect(link.folderKey.map(Base64URL.encode) == Live.folderKey)
    }

    @Test func `parses the legacy folder format with a selected file`() throws {
        let link = try #require(
            MegaLink("https://mega.nz/#F!\(Live.folderID)!\(Live.folderKey)!\(Live.smallFileHandle)")
        )
        #expect(link.selectedHandle == NodeHandle(Live.smallFileHandle))
    }

    @Test func `parses the legacy file format`() throws {
        let link = try #require(MegaLink("https://mega.nz/#!AbCdEfGh!\(fileKey)"))
        #expect(link.fileKey != nil)
        #expect(link.handle == NodeHandle("AbCdEfGh"))
    }

    @Test func `accepts mega.co.nz, a missing scheme and surrounding whitespace`() throws {
        for variant in [
            "https://mega.co.nz/folder/\(Live.folderID)#\(Live.folderKey)",
            "mega.nz/folder/\(Live.folderID)#\(Live.folderKey)",
            "  \(Live.folderURL)\n",
        ] {
            let link = try #require(MegaLink(variant), "failed to parse \(variant)")
            #expect(link.handle == folderHandle)
        }
    }

    @Test func `round-trips through its canonical URL`() throws {
        for variant in [Live.folderURL, "\(Live.folderURL)/file/\(Live.smallFileHandle)", "https://mega.nz/file/AbCdEfGh#\(fileKey)"] {
            let link = try #require(MegaLink(variant))
            #expect(MegaLink(link.url.absoluteString) == link)
        }
    }

    @Test(arguments: [
        "https://example.com/folder/7YdzBbYb#jH6VX0GcTngXCf6kBnQGDA",
        "https://mega.nz/folder/7YdzBbYb",
        "https://mega.nz/folder/7YdzBbYb#",
        "https://mega.nz/folder/7YdzBbYb#/",
        "https://mega.nz/folder/7YdzBbYb#//file/AbCdEfGh",
        "https://mega.nz/folder/#jH6VX0GcTngXCf6kBnQGDA",
        "https://mega.nz/file/AbCdEfGh#jH6VX0GcTngXCf6kBnQGDA",
        "https://mega.nz/#F!7YdzBbYb",
        "https://mega.nz/folder/7YdzBbYb#jH6VX0GcTngXCf6kBnQGDA/file/short",
        "not a link at all",
        "",
    ]) func `rejects malformed links`(input: String) {
        #expect(MegaLink(input) == nil)
    }
}

@Suite struct MultipleLinkParsingTests {
    private let folder = Live.folderURL
    private let file = "https://mega.nz/file/AbCdEfGh#\(fileKey)"

    @Test func `finds one link per line`() {
        let links = MegaLink.links(in: "\(folder)\n\(file)\n")
        #expect(links.count == 2)
        #expect(links[0].handle == folderHandle)
        #expect(links[1].handle == NodeHandle("AbCdEfGh"))
    }

    @Test(arguments: [" ", "\n", "\r\n", ", ", "; ", " | ", "\n\n  \n"])
    func `accepts assorted separators`(separator: String) {
        #expect(MegaLink.links(in: "\(folder)\(separator)\(file)").count == 2)
    }

    @Test func `ignores surrounding prose and punctuation`() {
        let text = "Here you go: \(folder), and also <\(file)>. Enjoy!"
        let links = MegaLink.links(in: text)
        #expect(links.count == 2)
        #expect(links[0].handle == folderHandle)
    }

    @Test func `drops duplicates while keeping the first order`() {
        let links = MegaLink.links(in: "\(file)\n\(folder)\n\(file)\n\(folder)")
        #expect(links.count == 2)
        #expect(links[0].handle == NodeHandle("AbCdEfGh"))
        #expect(links[1].handle == folderHandle)
    }

    @Test func `skips tokens that are not MEGA links`() {
        let text = "https://example.com/a\n\(folder)\nnot-a-link\nhttps://mega.nz/folder/broken"
        let links = MegaLink.links(in: text)
        #expect(links.count == 1)
        #expect(links[0].handle == folderHandle)
    }

    @Test func `returns nothing for text with no links`() {
        #expect(MegaLink.links(in: "").isEmpty)
        #expect(MegaLink.links(in: "just some words, nothing here").isEmpty)
    }

    @Test func `handles a single link exactly as the initializer does`() {
        let links = MegaLink.links(in: folder)
        #expect(links.count == 1)
        #expect(links[0] == MegaLink(folder))
    }
}
