import Foundation
import Testing
@testable import MegaKit

private enum Account {
    static let email = ProcessInfo.processInfo.environment["MEGA_EMAIL"]
    static let password = ProcessInfo.processInfo.environment["MEGA_PASSWORD"]
    static let secondFactor = ProcessInfo.processInfo.environment["MEGA_MFA"]

    static var credentials: AccountCredentials? {
        guard let email, let password else { return nil }
        return AccountCredentials(email: email, password: password, secondFactorCode: secondFactor)
    }
}

private let accountOnly: ConditionTrait = .enabled(
    if: Account.credentials != nil,
    "set MEGA_EMAIL and MEGA_PASSWORD to run tests against a real account"
)

@Suite(.serialized) struct AccountLiveTests {
    private func signedIn() async throws -> (MegaSession, MegaTree) {
        let credentials = try #require(Account.credentials)
        let api = APIClient()
        let account = try await MegaLogin.logIn(credentials, api: api)

        #expect(!account.sessionID.isEmpty)
        #expect(account.masterKey.count == 16)
        #expect(!account.userHandle.isEmpty)

        let session = MegaSession(account: account, api: api)
        return (session, try await session.loadTree())
    }

    @Test(accountOnly) func `signs in and lists the account tree`() async throws {
        let (_, tree) = try await signedIn()
        #expect(tree.roots.contains { $0.kind == .root })
        #expect(tree.nodesByHandle.values.allSatisfy { !$0.name.isEmpty })
    }

    @Test(accountOnly, .timeLimit(.minutes(5)))
    func `uploads a folder and file, downloads it back, then cleans up`() async throws {
        let (session, tree) = try await signedIn()
        let drive = try #require(tree.roots.first { $0.kind == .root })

        let scratch = FileManager.default.temporaryDirectory.appending(path: "up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let payload = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let localFile = scratch.appending(path: "omegadl-upload-test.bin")
        try payload.write(to: localFile)

        let folder = try await session.createFolder(named: "OmegaDL Test \(UUID().uuidString.prefix(8))", in: drive.handle)
        #expect(folder.kind == .folder)
        #expect(folder.folderKey?.count == 16)

        let uploaded = try await session.upload(
            fileAt: localFile, as: "omegadl-upload-test.bin", to: folder.handle
        )
        #expect(uploaded.name == "omegadl-upload-test.bin")
        #expect(uploaded.size == payload.count)
        #expect(uploaded.fileKey != nil)

        let reloaded = try await session.loadTree()
        #expect(reloaded.node(folder.handle) != nil)
        #expect(reloaded.node(uploaded.handle)?.name == "omegadl-upload-test.bin")
        #expect(reloaded.children(of: folder.handle).map(\.handle) == [uploaded.handle])

        let descriptor = try await session.downloadDescriptor(for: uploaded)
        let destination = scratch.appending(path: "roundtrip.bin")
        try await DownloadEngine().download(descriptor, to: destination)

        #expect(try Data(contentsOf: destination) == payload)

        try await session.delete(folder)
        let after = try await session.loadTree()
        #expect(after.node(folder.handle) == nil)
    }
}
