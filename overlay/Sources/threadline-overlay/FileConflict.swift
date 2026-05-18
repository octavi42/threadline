import Foundation

/// One agent's trust state on a file also touched by another agent.
struct AgentFileContribution: Equatable {
    let snapshotID: String
    let tool: String
    let work: WorkState

    var summaryLine: String {
        let detail = work.reason.isEmpty ? work.status.rawValue : work.reason
        let compact = detail.count > 42 ? String(detail.prefix(39)) + "…" : detail
        return "\(tool): \(work.status.rawValue) (\(compact))"
    }
}

/// Same file edited by multiple agents with different trust states.
struct FileAgentConflict: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let fileName: String
    let contributors: [AgentFileContribution]
    let recommendedSnapshotID: String?
    let suggestion: String
    let severity: Int

    var toolsLabel: String {
        contributors.map(\.tool).joined(separator: " + ")
    }
}

enum FileConflictDetector {
    /// Files where two or more active agents disagree on trust status.
    static func conflicts(in folder: SessionFolder,
                          workStates: [String: WorkState]) -> [FileAgentConflict] {
        folder.mergedFiles().compactMap { file in
            buildConflict(file: file, folder: folder, workStates: workStates)
        }
        .sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return a.path < b.path
        }
    }

    private static func buildConflict(file: FolderMergedFile,
                                      folder: SessionFolder,
                                      workStates: [String: WorkState]) -> FileAgentConflict? {
        var contributors: [AgentFileContribution] = []
        var seenTools: Set<String> = []

        for snapID in file.sourceSnapshotIDs {
            guard let snap = folder.snapshots.first(where: { $0.id == snapID }) else { continue }
            let work = workStates[snapID] ?? snap.workState
            contributors.append(AgentFileContribution(
                snapshotID: snapID,
                tool: snap.tool,
                work: work
            ))
            seenTools.insert(snap.tool)
        }

        guard contributors.count >= 2, seenTools.count >= 2 else { return nil }

        let active = contributors.filter { !WorkStatusResolver.isInactiveInbox($0.work) }
        guard active.count >= 2 else { return nil }

        let statuses = Set(active.map(\.work.status))
        guard statuses.count > 1 else { return nil }

        let sorted = active.sorted { lhs, rhs in
            let lp = trustReviewPriority(lhs.work.status)
            let rp = trustReviewPriority(rhs.work.status)
            if lp != rp { return lp < rp }
            return lhs.tool < rhs.tool
        }
        let priorities = active.map { trustReviewPriority($0.work.status) }
        let severity = (priorities.max() ?? 0) - (priorities.min() ?? 0)
        let best = sorted.first!

        return FileAgentConflict(
            path: file.path,
            fileName: (file.path as NSString).lastPathComponent,
            contributors: contributors.sorted {
                let lp = trustReviewPriority($0.work.status)
                let rp = trustReviewPriority($1.work.status)
                if lp != rp { return lp < rp }
                return $0.tool < $1.tool
            },
            recommendedSnapshotID: best.snapshotID,
            suggestion: suggestion(for: best),
            severity: severity
        )
    }

    /// Who to trust for overlapping edits — prefer verified (Ready) over unverified (Risky).
    private static func trustReviewPriority(_ status: WorkStatus) -> Int {
        switch status {
        case .needsYou: return 0
        case .testsFailed: return 1
        case .stuck: return 2
        case .ready: return 3
        case .working: return 4
        case .risky: return 5
        case .done: return 99
        }
    }

    private static func suggestion(for best: AgentFileContribution) -> String {
        switch best.work.status {
        case .needsYou:
            return "Answer \(best.tool) first"
        case .testsFailed:
            return "Fix \(best.tool) failures first"
        case .stuck:
            return "Unblock \(best.tool) first"
        case .ready:
            return "Review \(best.tool) first"
        case .risky, .working, .done:
            return "Check \(best.tool) first"
        }
    }
}

extension SessionFolder {
    func fileConflicts(workStates: [String: WorkState]) -> [FileAgentConflict] {
        FileConflictDetector.conflicts(in: self, workStates: workStates)
    }
}
