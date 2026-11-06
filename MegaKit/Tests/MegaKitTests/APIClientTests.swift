import CryptoKit
import Foundation
import Testing
@testable import MegaKit

@Suite(.serialized) struct APIClientLiveTests {
    @Test(liveOnly) func `resolves a download URL scoped to the folder`() async throws {
        let client = APIClient(.folder(NodeHandle(Live.folderID)!))

        let info: DownloadResponse = try await client.request(DownloadCommand(node: Live.smallFileHandle))
        #expect(info.s == Live.smallFileSize)
        #expect(try #require(info.g).hasPrefix("https://"))
    }

    @Test(liveOnly) func `surfaces a MEGA error code as a typed error`() async throws {
        let client = APIClient(.folder(NodeHandle(Live.folderID)!))

        await #expect(throws: MegaError.self) {
            let _: DownloadResponse = try await client.request(DownloadCommand(node: "AAAAAAAA"))
        }
    }
}

@Suite struct APIResponseTests {
    @Test(arguments: [("-15", -15), ("[-9]", -9), (" [ -999 ]", -999), ("[0,-9,-11]", -9)])
    func `spots an error code, bare, wrapped or among batch results`(body: String, code: Int) {
        #expect(APIClient.errorCode(in: Data(body.utf8)) == code)
    }

    @Test(arguments: ["[0]", "[0,0]", "[{\"f\":[]},-9]", "[]", "0"])
    func `does not mistake a result for an error`(body: String) {
        #expect(APIClient.errorCode(in: Data(body.utf8)) == nil)
    }

    @Test func `encodes node commands with only the fields each one sends`() throws {
        let (node, parent) = (NodeHandle("AbCdEfGh")!, NodeHandle("ZyXwVuTs")!)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode([NodeCommand.move(node, to: parent), .delete(node), .setAttributes(of: node, to: "x")])
        #expect(String(decoding: json, as: UTF8.self) == #"[{"a":"m","n":"AbCdEfGh","t":"ZyXwVuTs"},{"a":"d","n":"AbCdEfGh"},{"a":"a","at":"x","n":"AbCdEfGh"}]"#)
    }

    @Test func `unwraps the single-element array MEGA always returns`() throws {
        #expect(try APIClient.decode(Data("[0]".utf8)) == 0)
        let response: UploadResponse = try APIClient.decode(Data(#"[{"p":"https://x"}]"#.utf8))
        #expect(response.p == "https://x")
    }

    @Test func `rejects a body it cannot read at all`() {
        #expect(throws: MegaError.malformedResponse) {
            let _: UploadResponse = try APIClient.decode(Data("[]".utf8))
        }
    }
}

@Suite struct HashcashTests {
    @Test func `finds a nonce whose digest clears the threshold`() async throws {
        let token = Data((0..<48).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let challenge = "1:192:1700000000:\(Base64URL.encode(token))"
        let answer = try await APIClient.solveHashcash(challenge: challenge)

        let parts = answer.split(separator: ":")
        #expect(parts.count == 3 && parts[1] == Substring(Base64URL.encode(token)))
        let nonce = try #require(Base64URL.decode(String(parts[2])))
        let digest = SHA256.hash(data: nonce + Data(repeatElement(token, count: 262_144).joined()))
        #expect(digest.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian } <= 1 << 24)
    }
}
