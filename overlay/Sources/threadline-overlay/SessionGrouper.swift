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

    /// Flat sidebar rows — one `ForEach` item per visible row, stable ids.
    static func makeInboxRows(from folders: [SessionFolder],
                              collapsedFolderIDs: Set<String>) -> [InboxRow] {
        var rows: [InboxRow] = []
        for folder in folders {
            rows.append(.folderHeader(cwd: folder.cwd))
            guard !collapsedFolderIDs.contains(folder.cwd) else { continue }
            let snaps = folder.snapshots
            for (index, snap) in snaps.enumerated() {
                rows.append(.agent(snapshotID: snap.id,
                                   folderCWD: folder.cwd,
                                   isFirst: index == 0,
                                   isLast: index == snaps.count - 1))
            }
        }
        return rows
    }

    /// Folder cwd → snapshot id set (order ignored).
    static func folderMembership(_ folders: [SessionFolder]) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: folders.map {
            ($0.cwd, Set($0.snapshots.map(\.id)))
        })
    }

    /// Preserve existing inbox row order; append new rows; drop removed rows.
    static func mergeInboxRows(current: [InboxRow],
                               desired: [InboxRow]) -> [InboxRow] {
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        var merged: [InboxRow] = []
        merged.reserveCapacity(desired.count)

        for row in current {
            if let fresh = desiredByID[row.id] {
                merged.append(fresh)
            }
        }

        let kept = Set(merged.map(\.id))
        for row in desired where !kept.contains(row.id) {
            merged.append(row)
        }
        return merged
    }

    /// Build folders using stable cwd / agent order (not work-status sort).
    static func makeStableFolders(from snapshotsByID: [String: SourceSnapshot],
                                  folderOrder: [String],
                                  agentOrderByFolder: [String: [String]]) -> [SessionFolder] {
        folderOrder.compactMap { cwd in
            guard let agentIDs = agentOrderByFolder[cwd] else { return nil }
            let snaps = agentIDs.compactMap { snapshotsByID[$0] }
            guard !snaps.isEmpty else { return nil }
            return SessionFolder(cwd: cwd,
                                 snapshots: snaps,
                                 stats: SessionFolder.makeStats(from: snaps))
        }
    }
}
