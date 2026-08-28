import Foundation
import Testing
@testable import MegaKit

private struct FilesCommand: Encodable, Sendable {
    let a = "f"
    let c = 1
    let ca = 1
    let r = 1
}

private struct RawListing: Decodable, Sendable {
    struct Node: Decodable, Sendable {
        let h: String
        let t: Int
        let k: String?
        let s: Int?
    }
    let f: [Node]
    let sn: String?
}

private struct DownloadCommand: Encodable, Sendable {
    let a = "g"
    let g = 1
    let ssl = 2
    let n: String
}

private struct DownloadInfo: Decodable, Sendable {
    let g: String
    let s: Int
}

@Suite(.serialized) struct APIClientLiveTests {
    @Test(liveOnly) func `lists a public folder with no session`() async throws {
        let client = APIClient()
        await client.setFolderID(Live.folderID)

        let listing: RawListing = try await client.request(FilesCommand())
        #expect(listing.f.count == Live.nodeCount)
        #expect(listing.sn != nil)

        let root = try #require(listing.f.first { $0.h == Live.rootHandle })
        #expect(root.t == 1)
        #expect(root.k?.hasPrefix("\(Live.rootHandle):") == true)
        #expect(listing.f.first { $0.h == Live.largeFileHandle }?.s == Live.largeFileSize)
    }

    @Test(liveOnly) func `resolves a download URL scoped to the folder`() async throws {
        let client = APIClient()
        await client.setFolderID(Live.folderID)

        let info: DownloadInfo = try await client.request(DownloadCommand(n: Live.smallFileHandle))
        #expect(info.s == Live.smallFileSize)
        #expect(info.g.hasPrefix("https://"))
    }

    @Test(liveOnly) func `surfaces a MEGA error code as a typed error`() async throws {
        let client = APIClient()
        await client.setFolderID(Live.folderID)

        await #expect(throws: MegaError.self) {
            let _: DownloadInfo = try await client.request(DownloadCommand(n: "AAAAAAAA"))
        }
    }
}

private struct Listing: Decodable, Sendable {
    let f: [RawNode]
}

@Suite struct APIResponseDecodingTests {
    @Test func `unwraps the single-element array MEGA always returns`() throws {
        let listing: Listing = try APIClient.decode(Data(#"[{"f":[{"h":"AbCdEfGh","t":0}]}]"#.utf8))
        #expect(listing.f.count == 1)
        #expect(listing.f[0].h == "AbCdEfGh")
    }

    @Test func `treats a negative code inside the array as an error`() {
        #expect(throws: MegaError.api(.notFound)) {
            let _: Listing = try APIClient.decode(Data("[-9]".utf8))
        }
    }

    @Test func `treats a bare negative code as an error`() {
        #expect(throws: MegaError.api(.badSession)) {
            let _: Listing = try APIClient.decode(Data("-15".utf8))
        }
    }

    @Test func `accepts a zero result as success rather than an error`() throws {
        #expect(try APIClient.decode(Data("[0]".utf8)) == 0)
    }

    @Test func `surfaces an unmapped negative code`() {
        #expect(throws: MegaError.unrecognizedAPICode(-999)) {
            let _: Listing = try APIClient.decode(Data("[-999]".utf8))
        }
    }

    @Test func `rejects a body it cannot read at all`() {
        #expect(throws: MegaError.malformedResponse) {
            let _: Listing = try APIClient.decode(Data("[]".utf8))
        }
    }
}
