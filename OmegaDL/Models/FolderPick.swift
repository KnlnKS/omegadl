import MegaKit
import Observation

/// The files chosen from a folder link before downloading it.
@Observable
final class FolderPick: Identifiable {
    let source: Source
    var selection: FileSelection

    init(source: Source, root: MegaNode) {
        self.source = source
        selection = FileSelection(root: root)
    }
}

extension FolderPick: Hashable {
    static func == (lhs: FolderPick, rhs: FolderPick) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
