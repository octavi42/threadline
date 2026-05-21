import AppKit
import Foundation
import Combine

final class SessionModel: ObservableObject {
    @Published var snapshots: [SourceSnapshot] = []
    @Published var folders: [SessionFolder] = []
    @Published var selectedID: String?
    /// LLM summaries keyed by snapshot id (= absolute JSONL path with prefix).
    /// Lands asynchronously when the Summarizer completes a fetch.
    @Published var summaries: [String: String] = [:]
    /// File paths the user has expanded in the Files tab. Stored here so the
    /// 3-second refresh cycle doesn't reset the expansion state.
    @Published var expandedFiles: Set<String> = []
    /// Project folders the user collapsed in the agents sidebar. Absence means
    /// expanded; stored on the model so the 3-second refresh does not reset it.
    @Published var collapsedFolderIDs: Set<String> = []
    /// When false, hide `Done` sessions so the sidebar is an action inbox.
    @Published var showInactiveSessions = false
    /// When false, hide sessions older than 24h (live PIDs always stay visible).
    @Published var showOlderSessions = false
    /// When false, Cursor inbox shows only live `cursor-agent` processes (not 7-day disk history).
    @Published var showCursorHistorySessions = false
    /// Cursor sessions on disk hidden while `showCursorHistorySessions` is false.
    @Published private(set) var hiddenCursorHistoryCount = 0
    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "threadline.overlay.refresh", qos: .utility)
    private var refreshGeneration = 0
    private var currentPollInterval: TimeInterval = 3.0

    /// Treat anything modified within this window as "active enough to surface".
    let activeWindow: TimeInterval = 7 * 24 * 3600

    func start() {
        refresh()
        scheduleTimer(interval: 3.0)
    }

    func refresh() {
        refreshQueue.async { [weak self] in
            self?.performRefresh()
        }
    }

    private func performRefresh() {
        refreshGeneration += 1
        let generation = refreshGeneration

        let built = SessionSnapshotBuilder.build(
            includeCursorHistory: showCursorHistorySessions
        )
        let all = built.snapshots
        let folders = SessionGrouper.makeFolders(from: all)
        let pollInterval = Self.preferredPollInterval(for: all)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, generation == self.refreshGeneration else { return }
            self.applyRefresh(snapshots: all,
                              folders: folders,
                              pollInterval: pollInterval,
                              hiddenCursorHistory: built.hiddenCursorHistoryCount)
        }
    }

    private func applyRefresh(snapshots all: [SourceSnapshot],
                              folders: [SessionFolder],
                              pollInterval: TimeInterval,
                              hiddenCursorHistory: Int) {
        if all != snapshots { self.snapshots = all }
        if hiddenCursorHistory != hiddenCursorHistoryCount {
            hiddenCursorHistoryCount = hiddenCursorHistory
        }
        if folders != self.folders {
            self.folders = folders
            pruneCollapsedFolders(visible: folders.map(\.id))
        }
        let preferred = SessionGrouper.preferredSelectionID(
            snapshots: all,
            showInactive: showInactiveSessions,
            showOlder: showOlderSessions
        )
        maintainSelection(preferredID: preferred)
        if pollInterval != currentPollInterval {
            currentPollInterval = pollInterval
            scheduleTimer(interval: pollInterval)
        }
        WorkStatusResolver.pruneResolveCache(keeping: Set(all.map(\.id)))
        if let snap = selectedSnapshot {
            kickoffSummary(for: snap)
        }
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private static func preferredPollInterval(for snapshots: [SourceSnapshot]) -> TimeInterval {
        let active = snapshots.contains { $0.state == .running || $0.livePid != nil }
        return active ? 3.0 : 10.0
    }

    /// Trust label — deterministic and stable until the session log changes.
    func workState(for snap: SourceSnapshot) -> WorkState {
        snap.workState
    }

    /// Folders and sessions for the sidebar trust board (respects `showInactiveSessions`).
    var inboxFolders: [SessionFolder] {
        SessionGrouper.inboxFolders(from: folders,
                                     showInactive: showInactiveSessions,
                                     showOlder: showOlderSessions)
    }

    var inboxSnapshotCount: Int {
        inboxFolders.reduce(0) { $0 + $1.snapshots.count }
    }

    func isInboxVisible(_ snap: SourceSnapshot) -> Bool {
        WorkStatusResolver.isVisibleInInbox(
            snap,
            showInactive: showInactiveSessions,
            showOlder: showOlderSessions
        )
    }

    private func maintainSelection(preferredID: String?) {
        if let id = selectedID {
            if let snap = selectedSnapshot {
                if !isInboxVisible(snap) {
                    selectedID = preferredID
                }
                return
            }
            if selectedFolder != nil,
               inboxFolders.contains(where: { $0.selectionID == id }) {
                return
            }
        }
        selectedID = preferredID
    }

    func setShowInactiveSessions(_ value: Bool) {
        guard showInactiveSessions != value else { return }
        showInactiveSessions = value
        maintainSelection(preferredID: SessionGrouper.preferredSelectionID(
            snapshots: snapshots,
            showInactive: value,
            showOlder: showOlderSessions
        ))
    }

    func setShowOlderSessions(_ value: Bool) {
        guard showOlderSessions != value else { return }
        showOlderSessions = value
        maintainSelection(preferredID: SessionGrouper.preferredSelectionID(
            snapshots: snapshots,
            showInactive: showInactiveSessions,
            showOlder: value
        ))
    }

    func setShowCursorHistorySessions(_ value: Bool) {
        guard showCursorHistorySessions != value else { return }
        showCursorHistorySessions = value
        refresh()
    }

    private func normalizedCwd(_ cwd: String?) -> String {
        guard let cwd = cwd, !cwd.isEmpty else { return "Unknown" }
        return (cwd as NSString).standardizingPath
    }

    private func summaryContext(for snap: SourceSnapshot) -> SummaryContext {
        SummaryContext(
            projectName: snap.projectName,
            currentTask: snap.currentTask,
            lastTool: snap.lastTool,
            filesEdited: snap.filesEdited,
            activityLine: snap.activityLine
        )
    }

    static func deterministicBrief(for snap: SourceSnapshot) -> String? {
        let ctx = SummaryContext(
            projectName: snap.projectName,
            currentTask: snap.currentTask,
            lastTool: snap.lastTool,
            filesEdited: snap.filesEdited,
            activityLine: snap.activityLine
        )
        let goal = snap.jsonlPath.flatMap { Summarizer.extractOpeningGoal(from: $0) }
        if snap.tool == "Cursor",
           let path = snap.jsonlPath,
           Summarizer.isMostlyRedacted(jsonlPath: path) {
            var parts = ["Cursor stores redacted transcript text on disk."]
            if snap.activityLine != "—" {
                parts.append("Latest: \(snap.activityLine).")
            } else if let goal = goal, !goal.isEmpty {
                parts.append("Goal: \(SourceSnapshot.compactLine(goal, limit: 120, maxWords: 18, firstSentence: false)).")
            }
            return SourceSnapshot.normalizeBrief(parts.joined(separator: " "))
        }
        return Summarizer.structuralFallback(context: ctx, openingGoal: goal)
    }

    private func kickoffSummary(for snap: SourceSnapshot) {
        guard let path = snap.jsonlPath, let mtime = snap.updatedAt else { return }
        let id = snap.id

        guard Summarizer.shouldSummarize(tool: snap.tool, jsonlPath: path) else {
            if let brief = Self.deterministicBrief(for: snap) {
                let normalized = SourceSnapshot.normalizeBrief(brief)
                if summaries[id] != normalized { summaries[id] = normalized }
            }
            return
        }

        let ctx = summaryContext(for: snap)
        let cached = Summarizer.shared.summary(
            forJSONL: path,
            mtime: mtime,
            context: ctx,
            onUpdate: { [weak self] text in
                self?.summaries[id] = SourceSnapshot.normalizeBrief(text)
            }
        )
        if let cached = cached {
            let normalized = SourceSnapshot.normalizeBrief(cached)
            if summaries[id] != normalized { summaries[id] = normalized }
        }
    }

    var selectedSnapshot: SourceSnapshot? {
        guard let id = selectedID else { return nil }
        return snapshots.first { $0.id == id }
    }

    var selectedFolder: SessionFolder? {
        guard let id = selectedID, id.hasPrefix("folder:") else { return nil }
        if let inbox = inboxFolders.first(where: { $0.selectionID == id }) {
            return inbox
        }
        return folders.first { $0.selectionID == id }
    }

    /// Request a summary for the currently-selected snapshot. Shares the
    /// same kickoff path used during eager pre-warm.
    func requestSummaryForSelection() {
        guard let snap = selectedSnapshot else { return }
        kickoffSummary(for: snap)
    }

    @discardableResult
    func selectFolder(cwd: String) -> Bool {
        let target = normalizedCwd(cwd)
        guard let folder = folders.first(where: { normalizedCwd($0.cwd) == target }) else {
            return false
        }
        selectedID = folder.selectionID
        return true
    }

    @discardableResult
    func selectSnapshot(cwd: String, tool: String? = nil) -> Bool {
        let target = normalizedCwd(cwd)
        guard let snap = snapshots.first(where: { snap in
            normalizedCwd(snap.cwd) == target && (tool == nil || snap.tool == tool)
        }) else {
            return selectFolder(cwd: cwd)
        }
        selectedID = snap.id
        return true
    }

    @discardableResult
    func selectSnapshot(scope: ShellRegistry.Scope, allowFolderFallback: Bool = true) -> Bool {
        let target = normalizedCwd(scope.cwd)
        let normalizedTTY = TerminalIdentityResolver.normalizeTTY(scope.tty)
        let snap = snapshots.first { snap in
            normalizedCwd(snap.cwd) == target &&
            snap.terminalPID == scope.terminal?.appPID &&
            snap.terminalSurfaceID != nil &&
            snap.terminalSurfaceID == scope.terminal?.surfaceID
        } ?? snapshots.first { snap in
            normalizedCwd(snap.cwd) == target &&
            normalizedTTY != nil &&
            TerminalIdentityResolver.normalizeTTY(snap.tty) == normalizedTTY
        } ?? snapshots.first { snap in
            normalizedCwd(snap.cwd) == target &&
            snap.livePid.map { ShellRegistry.shared.isDescendantOf(pid: $0, ancestor: scope.shellPid) } == true
        }

        guard let snap = snap else {
            return allowFolderFallback ? selectFolder(cwd: scope.cwd) : false
        }
        mergeTerminalIdentity(snapshotID: snap.id,
                              tty: scope.tty,
                              terminal: scope.terminal)
        selectedID = snap.id
        return true
    }

    @discardableResult
    func selectSnapshot(terminal: TerminalIdentity) -> Bool {
        if let scope = ShellRegistry.shared.scope(terminal: terminal) {
            return selectSnapshot(scope: scope, allowFolderFallback: false)
        }
        let normalizedTTY = TerminalIdentityResolver.normalizeTTY(terminal.tty)
        let snap = snapshots.first { snap in
            terminal.surfaceID != nil &&
            snap.terminalPID == terminal.appPID &&
            snap.terminalSurfaceID == terminal.surfaceID
        } ?? snapshots.first { snap in
            normalizedTTY != nil &&
            TerminalIdentityResolver.normalizeTTY(snap.tty) == normalizedTTY
        }

        guard let snap = snap else {
            return false
        }
        mergeTerminalIdentity(snapshotID: snap.id,
                              tty: terminal.tty,
                              terminal: terminal)
        selectedID = snap.id
        return true
    }

    private func mergeTerminalIdentity(snapshotID: String,
                                       tty: String?,
                                       terminal: TerminalIdentity?) {
        guard let index = snapshots.firstIndex(where: { $0.id == snapshotID }) else { return }
        var snap = snapshots[index]
        if let normalizedTTY = TerminalIdentityResolver.normalizeTTY(tty), snap.tty == nil {
            snap.tty = normalizedTTY
        }
        if let terminal = terminal {
            snap.terminalBundleID = terminal.bundleID
            snap.terminalPID = terminal.appPID
            if let surfaceID = terminal.surfaceID { snap.terminalSurfaceID = surfaceID }
            if let windowID = terminal.windowID { snap.terminalWindowID = windowID }
            if let tabID = terminal.tabID { snap.terminalTabID = tabID }
            if let terminalTTY = TerminalIdentityResolver.normalizeTTY(terminal.tty), snap.tty == nil {
                snap.tty = terminalTTY
            }
        }
        guard snap != snapshots[index] else { return }
        snapshots[index] = snap
        folders = SessionGrouper.makeFolders(from: snapshots)
    }

    func isFolderExpanded(_ folderID: String) -> Bool {
        !collapsedFolderIDs.contains(folderID)
    }

    func toggleFolderExpansion(_ folderID: String) {
        if collapsedFolderIDs.contains(folderID) {
            collapsedFolderIDs.remove(folderID)
        } else {
            collapsedFolderIDs.insert(folderID)
        }
    }

    private func pruneCollapsedFolders(visible folderIDs: [String]) {
        let visibleSet = Set(folderIDs)
        collapsedFolderIDs = collapsedFolderIDs.intersection(visibleSet)
    }
}
