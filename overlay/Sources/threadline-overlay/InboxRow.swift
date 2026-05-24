import Foundation

/// One selectable row in the agents sidebar — flat list with stable identities.
enum InboxRow: Identifiable, Equatable {
    case folderHeader(cwd: String)
    case agent(snapshotID: String, folderCWD: String, isFirst: Bool, isLast: Bool)

    var id: String {
        switch self {
        case .folderHeader(let cwd):
            return "folder:\(cwd)"
        case .agent(let snapshotID, _, _, _):
            return snapshotID
        }
    }

    var selectionTag: String { id }
}
