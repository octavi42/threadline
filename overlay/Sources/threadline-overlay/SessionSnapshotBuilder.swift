import Foundation

enum SessionSnapshotBuilder {
    static func buildSnapshots() -> [SourceSnapshot] {
        var all: [SourceSnapshot] = []

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
        for snap in CursorAgentSource.readAll(since: diskCutoff).map(SourceSnapshot.withDerivedFields) {
            if seenIDs.insert(snap.id).inserted {
                all.append(snap)
            }
        }

        all = all.filter(WorkStatusResolver.shouldDisplay)
        all.sort(by: WorkStatusResolver.sort)
        return all
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
