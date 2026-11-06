import Foundation

public struct MegaLink: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file(MegaFileKey)
        case folder(AESBlock)
    }

    public let kind: Kind
    public let handle: NodeHandle
    public let selectedHandle: NodeHandle?

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased(),
              host == "mega.nz" || host == "mega.co.nz" || host.hasSuffix(".mega.nz"),
              let fragment = components.fragment, !fragment.isEmpty
        else { return nil }

        let segments = components.path.split(separator: "/")
        let parsed: (isFolder: Bool, handle: Substring, key: Substring, selected: Substring?)

        if segments.count == 2, segments[0] == "folder" || segments[0] == "file" {
            let pieces = fragment.split(separator: "/")
            guard let key = pieces.first else { return nil }
            parsed = (segments[0] == "folder", segments[1], key, pieces.count >= 3 ? pieces.last : nil)
        } else if segments.isEmpty {
            let pieces = fragment.split(separator: "!", omittingEmptySubsequences: false)
            guard pieces.count >= 3, pieces[0] == "F" || pieces[0].isEmpty else { return nil }
            parsed = (pieces[0] == "F", pieces[1], pieces[2], pieces.count >= 4 && !pieces[3].isEmpty ? pieces[3] : nil)
        } else {
            return nil
        }

        guard let handle = NodeHandle(String(parsed.handle)) else { return nil }
        var selected: NodeHandle?
        if let raw = parsed.selected {
            guard let handle = NodeHandle(String(raw)) else { return nil }
            selected = handle
        }

        guard let key = Base64URL.decode(String(parsed.key)) else { return nil }
        switch (parsed.isFolder, key.count) {
        case (true, 16): kind = .folder(key.withUnsafeBytes { AESBlock($0)! })
        case (false, 32): kind = .file(key.withUnsafeBytes { MegaFileKey(packed: $0)! })
        default: return nil
        }
        self.handle = handle
        self.selectedHandle = selected
    }

    public static func links(in text: String) -> [MegaLink] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|"))
        let trimmed = CharacterSet(charactersIn: "<>\"'`()[]{}.")

        var links = [MegaLink]()
        for token in text.components(separatedBy: separators) {
            if let link = MegaLink(token.trimmingCharacters(in: trimmed)), !links.contains(link) {
                links.append(link)
            }
        }
        return links
    }

    public var url: URL {
        var string = switch kind {
        case .folder(let key): "https://mega.nz/folder/\(handle)#\(Base64URL.encode(key))"
        case .file(let key): "https://mega.nz/file/\(handle)#\(withUnsafeBytes(of: key.packed, Base64URL.encode))"
        }
        if let selectedHandle { string += "/file/\(selectedHandle)" }
        return URL(string: string)!
    }
}
