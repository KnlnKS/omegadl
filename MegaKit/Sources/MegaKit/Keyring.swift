import CommonCrypto

/// The keys that unwrap node keys: a folder link's key for every node, or an account's master key
/// plus the share keys it holds.
struct Keyring: ~Copyable {
    private let primary: AESBlock
    private let decryptor: Cryptor
    /// The account's user handle; nil for a folder link.
    private let owner: String?
    private var shareHandles = [NodeHandle]()
    private var shareKeys = [AESBlock]()

    init(folderKey: AESBlock) {
        primary = folderKey
        decryptor = Cryptor(kCCDecrypt, mode: kCCModeECB, key: folderKey)
        owner = nil
    }

    init(account: AccountSession) {
        primary = account.masterKey
        decryptor = Cryptor(kCCDecrypt, mode: kCCModeECB, key: account.masterKey)
        owner = account.userHandle
    }

    /// Accepts a share key wrapped by the primary key, checking its authority value when present.
    mutating func addShare(handle: NodeHandle, wrapped: AESBlock, authority: AESBlock?) {
        if let authority {
            let ascii = AESBlock(Array(handle.description.utf8) + Array(handle.description.utf8))
            guard AES.encrypt(ascii, key: primary) == authority else { return }
        }
        let index = shareHandles.partitioningIndex { $0 >= handle }
        shareHandles.insert(handle, at: index)
        shareKeys.insert(decryptor(wrapped), at: index)
    }

    /// Calls `body` with each key in a node's `k` field this keyring can unwrap, until it returns true.
    /// The field is `holder:wrappedKey` segments joined by `/`.
    func forEachKey(in field: UnsafeRawBufferPointer, isFile: Bool, _ body: (MegaFileKey) -> Bool) {
        var start = 0
        while start < field.count {
            let end = field[start...].firstIndex(of: UInt8(ascii: "/")) ?? field.count
            let segment = field[start..<end]
            start = end + 1
            guard let colon = segment.firstIndex(of: UInt8(ascii: ":")),
                  let key = unwrap(UnsafeRawBufferPointer(rebasing: segment[(colon + 1)...]),
                                   holder: UnsafeRawBufferPointer(rebasing: segment[..<colon]), isFile: isFile)
            else { continue }
            if body(key) { return }
        }
    }

    /// The key wrapping a node key addressed to `holder`: a user handle or a share's node handle.
    func wrappingKey(for holder: UnsafeRawBufferPointer) -> AESBlock? {
        guard let owner else { return primary }
        if holder.elementsEqual(owner.utf8) { return primary }
        guard let handle = NodeHandle(holder) else { return nil }
        let index = shareHandles.partitioningIndex { $0 >= handle }
        return index < shareHandles.count && shareHandles[index] == handle ? shareKeys[index] : nil
    }

    private func unwrap(_ wrapped: UnsafeRawBufferPointer, holder: UnsafeRawBufferPointer, isFile: Bool) -> MegaFileKey? {
        guard let key = wrappingKey(for: holder) else { return nil }
        var blocks = (AESBlock(), AESBlock())
        let length = withUnsafeMutableBytes(of: &blocks) { Base64URL.decode(wrapped, into: $0) }
        guard length == 32 || (length == 16 && !isFile) else { return nil }
        return key == primary
            ? Self.open(blocks, isFile: isFile, with: decryptor)
            : Self.open(blocks, isFile: isFile, with: Cryptor(kCCDecrypt, mode: kCCModeECB, key: key))
    }

    private static func open(_ blocks: (AESBlock, AESBlock), isFile: Bool, with cryptor: borrowing Cryptor) -> MegaFileKey {
        isFile
            ? MegaFileKey(head: cryptor(blocks.0), tail: cryptor(blocks.1))
            : MegaFileKey(aesKey: cryptor(blocks.0), nonce: .zero, metaMAC: .zero)
    }
}
