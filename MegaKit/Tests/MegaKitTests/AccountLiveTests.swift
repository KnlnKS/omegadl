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
        let account = try await MegaLogin.logIn(credentials)

        #expect(!account.sessionID.isEmpty)
        #expect(!account.userHandle.isEmpty)

        let session = MegaSession(account: account)
        return (session, try await session.loadTree())
    }

    @Test(accountOnly) func `signs in and lists the account tree`() async throws {
        let (_, tree) = try await signedIn()
        #expect(tree.roots.contains { $0.kind == .root })
        #expect((0..<tree.count).allSatisfy { !tree[$0].name.isEmpty })
    }

    @Test(accountOnly, .timeLimit(.minutes(5)))
    func `moves a file to the rubbish bin, puts it back, then deletes it`() async throws {
        let (session, tree) = try await signedIn()
        let drive = try #require(tree.roots.first { $0.kind == .root })
        let rubbish = try #require(tree.roots.first { $0.kind == .rubbish })

        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let folder = try await session.createFolder(named: "OmegaDL Rubbish Test", in: drive.id)
        let local = scratch.appending(path: "discard.bin")
        try Data(repeating: 3, count: 4096).write(to: local)
        let uploaded = try await session.upload(fileAt: local, as: "discard.bin", to: folder.id)

        let listed = try #require(try await session.loadTree().node(uploaded.id))
        try await session.move([listed], to: rubbish.id, recordingOrigin: true)

        let inBin = try #require(try await session.loadTree().node(uploaded.id))
        #expect(inBin.parent?.id == rubbish.id)
        #expect(inBin.restoreTarget?.id == folder.id)
        #expect(inBin.name == "discard.bin")

        try await session.putBack([inBin])

        let restored = try await session.loadTree()
        #expect(restored.node(uploaded.id)?.parent?.id == folder.id)

        try await session.delete([try #require(restored.node(folder.id))])
        #expect(try await session.loadTree().node(folder.id) == nil)
    }

    @Test(accountOnly, .timeLimit(.minutes(5)))
    func `uploads a folder and file, downloads it back, then cleans up`() async throws {
        let (session, tree) = try await signedIn()
        let drive = try #require(tree.roots.first { $0.kind == .root })

        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let payload = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let localFile = scratch.appending(path: "omegadl-upload-test.bin")
        try payload.write(to: localFile)

        let folder = try await session.createFolder(named: "OmegaDL Test \(UUID().uuidString.prefix(8))", in: drive.id)
        #expect(folder.kind == .folder)
        #expect(folder.attributeKey != nil)

        let uploaded = try await session.upload(
            fileAt: localFile, as: "omegadl-upload-test.bin", to: folder.id,
            engine: UploadEngine(maximumConnections: 4, segmentSize: 1 << 20)
        )
        #expect(uploaded.name == "omegadl-upload-test.bin")
        #expect(uploaded.size == payload.count)
        #expect(uploaded.fileKey != nil)

        let reloaded = try await session.loadTree()
        #expect(reloaded.node(uploaded.id)?.name == "omegadl-upload-test.bin")
        #expect(reloaded.node(folder.id)?.children.map(\.id) == [uploaded.id])

        let descriptor = try await session.downloadDescriptor(for: uploaded)
        let destination = scratch.appending(path: "roundtrip.bin")
        try await DownloadEngine().download(descriptor, to: destination)

        #expect(try Data(contentsOf: destination) == payload)

        try await session.delete([folder])
        let after = try await session.loadTree()
        #expect(after.node(folder.id) == nil)
    }
}
