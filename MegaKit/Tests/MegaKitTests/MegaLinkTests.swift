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
