import Foundation

public struct MegaLink: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case file
        case folder
    }

    public let kind: Kind
    public let handle: String
    public let key: Data
    public let selectedHandle: String?

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased(),
              host == "mega.nz" || host == "mega.co.nz" || host.hasSuffix(".mega.nz"),
              let fragment = components.fragment, !fragment.isEmpty
        else { return nil }

        let segments = components.path.split(separator: "/").map(String.init)
        let parsed: (Kind, String, String, String?)?

        if segments.count == 2, segments[0] == "folder" || segments[0] == "file" {
            let pieces = fragment.split(separator: "/").map(String.init)
            parsed = (
                segments[0] == "folder" ? .folder : .file,
                segments[1],
                pieces[0],
                pieces.count >= 3 ? pieces[pieces.count - 1] : nil
            )
        } else if segments.isEmpty {
            let pieces = fragment.split(separator: "!", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count >= 3, pieces[0] == "F" || pieces[0].isEmpty else { return nil }
            parsed = (
                pieces[0] == "F" ? .folder : .file,
                pieces[1],
                pieces[2],
                pieces.count >= 4 && !pieces[3].isEmpty ? pieces[3] : nil
            )
        } else {
            parsed = nil
        }

        guard let (kind, handle, encodedKey, selected) = parsed,
              !handle.isEmpty,
              let key = Base64URL.decode(encodedKey),
              key.count == (kind == .folder ? 16 : 32)
        else { return nil }

        self.kind = kind
        self.handle = handle
        self.key = key
        self.selectedHandle = selected
    }

    public static func links(in text: String) -> [MegaLink] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|"))
        let trimmed = CharacterSet(charactersIn: "<>\"'`()[]{}.")

        var seen = Set<MegaLink>()
        return text.components(separatedBy: separators).compactMap { token in
            guard let link = MegaLink(token.trimmingCharacters(in: trimmed)) else { return nil }
            return seen.insert(link).inserted ? link : nil
        }
    }

    public var url: URL {
        var string = "https://mega.nz/\(kind == .folder ? "folder" : "file")/\(handle)#\(Base64URL.encode(key))"
        if let selectedHandle { string += "/file/\(selectedHandle)" }
        return URL(string: string)!
    }
}
