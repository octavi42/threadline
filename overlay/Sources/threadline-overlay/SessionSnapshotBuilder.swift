import Foundation

enum SessionSnapshotBuilder {
    /// When `includeCursorHistory` is false, only live Cursor Agent processes appear
    /// (no 7-day disk scan). Claude/Codex behavior is unchanged.
    struct BuildResult {
        let snapshots: [SourceSnapshot]
        /// Cursor JSONL on disk not shown while history toggle is off.
        let hiddenCursorHistoryCount: Int
    }

    static func build(includeCursorHistory: Bool = false) -> BuildResult {
        var all: [SourceSnapshot] = []
        var hiddenCursorHistory = 0

        for session in LiveAgents.liveSessions() {
            var snap: SourceSnapshot?
            switch session.tool {
            case "Claude": snap = ClaudeSource.snapshot(forJSONL: session.jsonlPath)
            case "Codex":  snap = CodexSource.snapshot(forJSONL: session.jsonlPath)
            case "Cursor": snap = CursorAgentSource.snapshot(forJSONL: session.jsonlPath)
            default:       snap = nil
            }
            if var s = snap {
                enrichWithLiveIdentity(&s, session: session)
                all.append(SourceSnapshot.withDerivedFields(s))
            }
        }

        var seenIDs = Set(all.map(\.id))
        let diskCutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let diskCursor = CursorAgentSource.readAll(since: diskCutoff)
            .map(SourceSnapshot.withDerivedFields)

        if includeCursorHistory {
            for snap in diskCursor where seenIDs.insert(snap.id).inserted {
                all.append(snap)
            }
        } else {
            hiddenCursorHistory = diskCursor.filter { !seenIDs.contains($0.id) }.count
        }

        all = all.filter(WorkStatusResolver.shouldDisplay)
        all.sort(by: WorkStatusResolver.sort)
        return BuildResult(snapshots: all, hiddenCursorHistoryCount: hiddenCursorHistory)
    }

    static func buildSnapshots(includeCursorHistory: Bool = false) -> [SourceSnapshot] {
        build(includeCursorHistory: includeCursorHistory).snapshots
    }

    private static func enrichWithLiveIdentity(_ snap: inout SourceSnapshot,
                                               session: LiveSession) {
        snap.livePid = session.pid
        if let shell = ShellRegistry.shared.shell(forDescendant: session.pid) {
            snap.tty = shell.tty
            snap.terminalBundleID = shell.terminal?.bundleID
            snap.terminalPID = shell.terminal?.appPID
            snap.terminalSurfaceID = shell.terminal?.surfaceID
            snap.terminalWindowID = shell.terminal?.windowID
            snap.terminalTabID = shell.terminal?.tabID
        } else if let terminal = TerminalIdentityResolver.resolve(agentPid: session.pid,
                                                                  cwd: snap.cwd) {
            snap.tty = terminal.tty
            snap.terminalBundleID = terminal.bundleID
            snap.terminalPID = terminal.appPID
            snap.terminalSurfaceID = terminal.surfaceID
            snap.terminalWindowID = terminal.windowID
            snap.terminalTabID = terminal.tabID
        }
    }
}
