import Foundation
import Testing
@testable import MegaKit

@Suite struct MegaLinkTests {
    @Test func `parses the current folder format`() throws {
        let link = try #require(MegaLink(Live.folderURL))
        #expect(link.kind == .folder)
        #expect(link.handle == Live.folderID)
        #expect(link.key.count == 16)
        #expect(Base64URL.encode(link.key) == Live.folderKey)
        #expect(link.selectedHandle == nil)
    }

    @Test func `parses a file selected inside a folder`() throws {
        let link = try #require(MegaLink("\(Live.folderURL)/file/\(Live.smallFileHandle)"))
        #expect(link.kind == .folder)
        #expect(link.handle == Live.folderID)
        #expect(link.selectedHandle == Live.smallFileHandle)
    }

    @Test func `parses a subfolder path in the fragment`() throws {
        let link = try #require(MegaLink("\(Live.folderURL)/folder/AbCdEfGh"))
        #expect(link.kind == .folder)
        #expect(link.selectedHandle == "AbCdEfGh")
    }

    @Test func `parses the current file format`() throws {
        let key = Base64URL.encode(Data((0..<32).map(UInt8.init)))
        let link = try #require(MegaLink("https://mega.nz/file/AbCdEfGh#\(key)"))
        #expect(link.kind == .file)
        #expect(link.handle == "AbCdEfGh")
        #expect(link.key.count == 32)
    }

    @Test func `parses the legacy folder format`() throws {
        let link = try #require(MegaLink("https://mega.nz/#F!\(Live.folderID)!\(Live.folderKey)"))
        #expect(link.kind == .folder)
        #expect(link.handle == Live.folderID)
        #expect(Base64URL.encode(link.key) == Live.folderKey)
    }

    @Test func `parses the legacy folder format with a selected file`() throws {
        let link = try #require(
            MegaLink("https://mega.nz/#F!\(Live.folderID)!\(Live.folderKey)!\(Live.smallFileHandle)")
        )
        #expect(link.selectedHandle == Live.smallFileHandle)
    }

    @Test func `parses the legacy file format`() throws {
        let key = Base64URL.encode(Data((0..<32).map(UInt8.init)))
        let link = try #require(MegaLink("https://mega.nz/#!AbCdEfGh!\(key)"))
        #expect(link.kind == .file)
        #expect(link.handle == "AbCdEfGh")
    }

    @Test func `accepts mega.co.nz, a missing scheme and surrounding whitespace`() throws {
        for variant in [
            "https://mega.co.nz/folder/\(Live.folderID)#\(Live.folderKey)",
            "mega.nz/folder/\(Live.folderID)#\(Live.folderKey)",
            "  \(Live.folderURL)\n",
        ] {
            let link = try #require(MegaLink(variant), "failed to parse \(variant)")
            #expect(link.handle == Live.folderID)
        }
    }

    @Test func `round-trips through its canonical URL`() throws {
        for variant in [Live.folderURL, "\(Live.folderURL)/file/\(Live.smallFileHandle)"] {
            let link = try #require(MegaLink(variant))
            #expect(MegaLink(link.url.absoluteString) == link)
        }
    }

    @Test(arguments: [
        "https://example.com/folder/7YdzBbYb#jH6VX0GcTngXCf6kBnQGDA",
        "https://mega.nz/folder/7YdzBbYb",
        "https://mega.nz/folder/7YdzBbYb#",
        "https://mega.nz/folder/#jH6VX0GcTngXCf6kBnQGDA",
        "https://mega.nz/file/AbCdEfGh#jH6VX0GcTngXCf6kBnQGDA",
        "https://mega.nz/#F!7YdzBbYb",
        "not a link at all",
        "",
    ]) func `rejects malformed links`(input: String) {
        #expect(MegaLink(input) == nil)
    }
}

@Suite struct MultipleLinkParsingTests {
    private let folder = Live.folderURL
    private let file = "https://mega.nz/file/AbCdEfGh#\(Base64URL.encode(Data((0..<32).map(UInt8.init))))"

    @Test func `finds one link per line`() {
        let links = MegaLink.links(in: "\(folder)\n\(file)\n")
        #expect(links.count == 2)
        #expect(links[0].handle == Live.folderID)
        #expect(links[1].handle == "AbCdEfGh")
    }

    @Test(arguments: [" ", "\n", "\r\n", ", ", "; ", " | ", "\n\n  \n"])
    func `accepts assorted separators`(separator: String) {
        #expect(MegaLink.links(in: "\(folder)\(separator)\(file)").count == 2)
    }

    @Test func `ignores surrounding prose and punctuation`() {
        let text = "Here you go: \(folder), and also <\(file)>. Enjoy!"
        let links = MegaLink.links(in: text)
        #expect(links.count == 2)
        #expect(links[0].handle == Live.folderID)
    }

    @Test func `drops duplicates while keeping the first order`() {
        let links = MegaLink.links(in: "\(file)\n\(folder)\n\(file)\n\(folder)")
        #expect(links.count == 2)
        #expect(links[0].handle == "AbCdEfGh")
        #expect(links[1].handle == Live.folderID)
    }

    @Test func `skips tokens that are not MEGA links`() {
        let text = "https://example.com/a\n\(folder)\nnot-a-link\nhttps://mega.nz/folder/broken"
        let links = MegaLink.links(in: text)
        #expect(links.count == 1)
        #expect(links[0].handle == Live.folderID)
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
