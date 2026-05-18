import Foundation

enum SessionGrouper {
    static func makeFolders(from snapshots: [SourceSnapshot]) -> [SessionFolder] {
        let grouped = Dictionary(grouping: snapshots) { snap in
            guard let cwd = snap.cwd, !cwd.isEmpty else { return "Unknown" }
            return (cwd as NSString).standardizingPath
        }
        return grouped.map { cwd, snaps in
            let sorted = snaps.sorted(by: WorkStatusResolver.sort)
            return SessionFolder(cwd: cwd,
                                 snapshots: sorted,
                                 stats: SessionFolder.makeStats(from: sorted))
        }
        .sorted { a, b in
            WorkStatusResolver.folderSort(a, b, workStates: [:])
        }
    }

    static func inboxFolders(from folders: [SessionFolder],
                             showInactive: Bool,
                             showOlder: Bool) -> [SessionFolder] {
        let mapped: [SessionFolder] = folders.compactMap { folder in
            let visible = folder.visibleSnapshots(
                showInactive: showInactive,
                showOlder: showOlder,
                workStates: [:]
            )
            guard !visible.isEmpty else { return nil }
            var f = folder
            f.snapshots = visible
            f.stats = SessionFolder.makeStats(from: visible)
            return f
        }
        return mapped.sorted { WorkStatusResolver.folderSort($0, $1, workStates: [:]) }
    }

    static func preferredSelectionID(snapshots: [SourceSnapshot],
                                     showInactive: Bool,
                                     showOlder: Bool) -> String? {
        snapshots
            .filter {
                WorkStatusResolver.isVisibleInInbox(
                    $0,
                    showInactive: showInactive,
                    showOlder: showOlder
                )
            }
            .first?
            .id
    }
}
