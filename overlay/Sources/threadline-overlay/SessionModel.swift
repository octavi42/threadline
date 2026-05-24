import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
final class SessionModel {
    private(set) var snapshots: [SourceSnapshot] = []
    private(set) var folders: [SessionFolder] = []
    private(set) var inboxRows: [InboxRow] = []
    private(set) var hiddenDoneCount = 0
    private(set) var hiddenOlderCount = 0
    private(set) var hasAnySnapshots = false
    var selectedID: String?
    var summaries: [String: String] = [:]
    var expandedFiles: Set<String> = []
    var collapsedFolderIDs: Set<String> = []
    var showInactiveSessions = false
    var showOlderSessions = false
    var showCursorHistorySessions = false
    private(set) var hiddenCursorHistoryCount = 0
    private(set) var lastRefreshAt: Date?
    private(set) var contentVersion: UInt64 = 0

    private var cellsByID: [String: SnapshotCell] = [:]
    private var snapshotByID: [String: SourceSnapshot] = [:]
    private var stableFolderOrder: [String] = []
    private var stableAgentOrder: [String: [String]] = [:]
    private var lastSummaryMtime: [String: Date] = [:]
    private var liveJSONLMtimes: [String: Date] = [:]
    private var timer: Timer?
    private var liveStatusTimer: Timer?
    private var logWatcher: SessionLogWatcher?
    private let refreshQueue = DispatchQueue(label: "threadline.overlay.refresh", qos: .utility)
    private var refreshGeneration = 0
    private var fullRefreshInFlight = false
    private var fullRefreshPending = false
    private var currentPollInterval: TimeInterval = 3.0

    let activeWindow: TimeInterval = 7 * 24 * 3600

    func start() {
        _ = loadIndexedSessionsForStartup()
        // Cached rows are only a fast first paint. A full reconciliation is
        // required to add new sessions and remove stale live identity.
        refresh()
        logWatcher = SessionLogWatcher { [weak self] paths in
            self?.hotRefresh(changedPaths: paths)
        }
        logWatcher?.start()
        scheduleLiveStatusTimer()
    }

    deinit {
        timer?.invalidate()
        liveStatusTimer?.invalidate()
        logWatcher?.stop()
    }

    func refresh() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        if fullRefreshInFlight {
            fullRefreshPending = true
            return
        }
        fullRefreshInFlight = true
        refreshQueue.async { [weak self] in
            self?.performRefresh()
        }
    }

    func refreshLiveSessionsOnly() {
        refreshQueue.async { [weak self] in
            let updates = JSONLAccess.sync {
                LiveAgents.liveSessions().compactMap { session -> SourceSnapshot? in
                    guard let snap = SessionSnapshotBuilder.snapshot(for: session) else { return nil }
                    return Self.snapshotWithLiveWorkState(snap)
                }
            }
            guard !updates.isEmpty else { return }
            DispatchQueue.main.async {
                OverlayLog.write("live startup refresh updates=\(updates.count)")
                self?.applyHotUpdates(updates)
            }
        }
    }

    /// Fast path for FSEvents — reparse only changed JSONL files, skip full disk scan.
    func hotRefresh(changedPaths: [String]) {
        refreshQueue.async { [weak self] in
            self?.performHotRefresh(changedPaths: changedPaths)
        }
    }

    func cell(for id: String) -> SnapshotCell? {
        cellsByID[id]
    }

    func snapshot(id: String) -> SourceSnapshot? {
        cellsByID[id]?.snapshot ?? snapshotByID[id]
    }

    /// Latest snapshot payloads (post-apply), for export and selection helpers.
    var allSnapshots: [SourceSnapshot] {
        Array(snapshotByID.values).sorted(by: WorkStatusResolver.sort)
    }

    func inboxFolder(cwd: String) -> SessionFolder? {
        inboxFoldersList().first { $0.cwd == cwd }
    }

    private func performRefresh() {
        refreshGeneration += 1
        let generation = refreshGeneration

        let includeCursorHistory = showCursorHistorySessions
        OverlayLog.write("refresh start generation=\(generation) cursorHistory=\(includeCursorHistory)")
        let built = JSONLAccess.sync {
            SessionSnapshotBuilder.build(includeCursorHistory: includeCursorHistory)
        }
        let all = JSONLAccess.sync {
            built.snapshots
                .map(Self.snapshotWithLiveWorkState)
                .sorted(by: WorkStatusResolver.sort)
        }
        let pollInterval = Self.preferredPollInterval(for: all)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fullRefreshInFlight = false
            guard generation == self.refreshGeneration else { return }
            OverlayLog.write("refresh apply generation=\(generation) snapshots=\(all.count)")
            self.applyRefresh(snapshots: all,
                              pollInterval: pollInterval,
                              hiddenCursorHistory: built.hiddenCursorHistoryCount,
                              schedulePolling: true)
            SessionStateStore.save(snapshots: self.allSnapshots)
            SnapshotDiskCache.save(snapshots: self.allSnapshots, selectedID: self.selectedID)
            if self.fullRefreshPending {
                self.fullRefreshPending = false
                self.refresh()
            }
        }
    }

    @discardableResult
    private func loadIndexedSessionsForStartup() -> Bool {
        let indexed = SessionStateStore.load()
        if !indexed.isEmpty {
            applyRefresh(snapshots: indexed,
                         pollInterval: Self.preferredPollInterval(for: indexed),
                         hiddenCursorHistory: hiddenCursorHistoryCount,
                         schedulePolling: false)
            return true
        }
        return loadCachedSnapshotsForStartup()
    }

    @discardableResult
    private func loadCachedSnapshotsForStartup() -> Bool {
        guard let cached = SnapshotDiskCache.load() else { return false }
        applyRefresh(snapshots: cached.snapshots,
                     pollInterval: Self.preferredPollInterval(for: cached.snapshots),
                     hiddenCursorHistory: hiddenCursorHistoryCount,
                     schedulePolling: false)
        if let cachedSelected = cached.selectedID, snapshot(id: cachedSelected) != nil {
            selectedID = cachedSelected
        }
        SessionStateStore.save(snapshots: allSnapshots)
        return true
    }

    private func performHotRefresh(changedPaths: [String]) {
        OverlayLog.write("hot refresh event changed=\(changedPaths.count)")
        let jsonlPaths = JSONLAccess.sync { matchingJSONLPaths(changedPaths) }
        guard !jsonlPaths.isEmpty else {
            OverlayLog.write("hot refresh ignored no-live-jsonl changed=\(changedPaths.count)")
            refreshLiveSessionsOnly()
            return
        }

        let updates = JSONLAccess.sync { () -> [SourceSnapshot] in
            let liveByPath = Dictionary(uniqueKeysWithValues: LiveAgents.liveSessions().map { ($0.jsonlPath, $0) })
            var snapshots: [SourceSnapshot] = []
            snapshots.reserveCapacity(jsonlPaths.count)

            for path in jsonlPaths {
                guard let session = liveByPath[path],
                      let snap = SessionSnapshotBuilder.snapshot(for: session) else { continue }
                snapshots.append(Self.snapshotWithLiveWorkState(snap))
            }
            return snapshots
        }

        guard !updates.isEmpty else {
            OverlayLog.write("hot refresh no snapshots paths=\(jsonlPaths.count)")
            refreshLiveSessionsOnly()
            return
        }
        OverlayLog.write("hot refresh parsed updates=\(updates.count) statuses=\(Self.statusSummary(updates))")
        DispatchQueue.main.async { [weak self] in
            self?.applyHotUpdates(updates)
        }
    }

    private func matchingJSONLPaths(_ changed: [String]) -> Set<String> {
        var paths = Set(changed.filter { $0.hasSuffix(".jsonl") })
        let livePaths = LiveAgents.liveSessions().map(\.jsonlPath)
        if paths.isEmpty {
            for path in changed {
                for jsonl in livePaths where jsonl.hasPrefix(path) {
                    paths.insert(jsonl)
                }
            }
        }
        return paths.intersection(Set(livePaths))
    }

    private func applyHotUpdates(_ updates: [SourceSnapshot]) {
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            var membershipChanged = false
            for snap in updates {
                if let path = snap.jsonlPath, let mtime = snap.updatedAt {
                    liveJSONLMtimes[path] = mtime
                }
                if let cell = cellsByID[snap.id] {
                    let old = cell.snapshot
                    cell.apply(snap)
                    snapshotByID[snap.id] = cell.snapshot
                    if old.workState != cell.snapshot.workState || old.activityLine != cell.snapshot.activityLine || old.updatedAt != cell.snapshot.updatedAt {
                        OverlayLog.write("hot apply id=\(snap.id) status=\(old.workState.status.rawValue)->\(cell.snapshot.workState.status.rawValue) updated=\(String(describing: old.updatedAt))->\(String(describing: cell.snapshot.updatedAt))")
                    }
                } else {
                    let cell = SnapshotCell(snapshot: snap)
                    cell.apply(snap)
                    cellsByID[snap.id] = cell
                    snapshotByID[snap.id] = cell.snapshot
                    registerStableOrder(for: snap)
                    membershipChanged = true
                }
            }
            if membershipChanged {
                OverlayLog.write("hot refresh added membership updates=\(updates.count)")
                syncStableFoldersFromSnapshots()
                rebuildInboxRows(force: true)
            }
            syncSnapshotsArray(from: Array(snapshotByID.values), membershipChanged: membershipChanged)
            refreshInboxStats()
            lastRefreshAt = Date()
            contentVersion &+= 1
        }
        SessionStateStore.save(snapshots: allSnapshots)
    }

    private func applyRefresh(snapshots all: [SourceSnapshot],
                              pollInterval: TimeInterval,
                              hiddenCursorHistory: Int,
                              schedulePolling: Bool = false) {
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            let membershipChanged = mergeSnapshots(all)
            if hiddenCursorHistory != hiddenCursorHistoryCount {
                hiddenCursorHistoryCount = hiddenCursorHistory
            }

            syncStableFoldersFromSnapshots()
            rebuildInboxRows(force: membershipChanged)
            refreshInboxStats()

            let preferred = SessionGrouper.preferredSelectionID(
                snapshots: snapshots,
                showInactive: showInactiveSessions,
                showOlder: showOlderSessions
            )
            maintainSelection(preferredID: preferred)

            if schedulePolling && (timer == nil || pollInterval != currentPollInterval) {
                currentPollInterval = pollInterval
                scheduleTimer(interval: pollInterval)
            } else {
                currentPollInterval = pollInterval
            }
            WorkStatusResolver.pruneResolveCache(keeping: Set(snapshotByID.keys))
            lastRefreshAt = Date()
            contentVersion &+= 1
            if let snap = selectedSnapshot {
                kickoffSummaryIfNeeded(for: snap)
            }
        }
    }

    /// Update cells in place; only replace `snapshots` when membership changes.
    @discardableResult
    private func mergeSnapshots(_ incoming: [SourceSnapshot]) -> Bool {
        let incomingIDs = Set(incoming.map(\.id))
        var membershipChanged = false

        for id in Set(cellsByID.keys).subtracting(incomingIDs) {
            cellsByID.removeValue(forKey: id)
            snapshotByID.removeValue(forKey: id)
            removeFromStableOrder(snapshotID: id)
            membershipChanged = true
        }

        for snap in incoming {
            if let cell = cellsByID[snap.id] {
                cell.apply(snap)
                snapshotByID[snap.id] = cell.snapshot
            } else {
                let cell = SnapshotCell(snapshot: snap)
                cell.apply(snap)
                cellsByID[snap.id] = cell
                snapshotByID[snap.id] = cell.snapshot
                registerStableOrder(for: snap)
                membershipChanged = true
            }
        }

        syncSnapshotsArray(from: incoming, membershipChanged: membershipChanged)
        return membershipChanged
    }

    /// Keep `snapshots` payloads fresh without reordering when membership is stable.
    private func syncSnapshotsArray(from incoming: [SourceSnapshot], membershipChanged: Bool) {
        if membershipChanged {
            snapshots = incoming.sorted(by: WorkStatusResolver.sort)
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, snapshotByID[$0.id] ?? $0) })
        for index in snapshots.indices {
            let id = snapshots[index].id
            if let fresh = byID[id] {
                snapshots[index] = fresh
            }
        }
        for snap in incoming where !snapshots.contains(where: { $0.id == snap.id }) {
            snapshots.append(snapshotByID[snap.id] ?? snap)
        }
    }

    private func registerStableOrder(for snap: SourceSnapshot) {
        guard let cwd = snap.cwd, !cwd.isEmpty else { return }
        let path = (cwd as NSString).standardizingPath
        if !stableFolderOrder.contains(path) {
            stableFolderOrder.append(path)
        }
        var agents = stableAgentOrder[path] ?? []
        if !agents.contains(snap.id) {
            agents.append(snap.id)
            stableAgentOrder[path] = agents
        }
    }

    private func removeFromStableOrder(snapshotID: String) {
        for cwd in stableFolderOrder {
            guard var agents = stableAgentOrder[cwd] else { continue }
            let before = agents.count
            agents.removeAll { $0 == snapshotID }
            if agents.count != before {
                stableAgentOrder[cwd] = agents.isEmpty ? nil : agents
            }
        }
        stableFolderOrder.removeAll { cwd in
            (stableAgentOrder[cwd] ?? []).isEmpty
        }
    }

    /// Refresh folder snapshot payloads without treating reorder as structural.
    private func syncStableFoldersFromSnapshots() {
        folders = SessionGrouper.makeStableFolders(from: snapshotByID,
                                                   folderOrder: stableFolderOrder,
                                                   agentOrderByFolder: stableAgentOrder)
    }

    private func rebuildInboxRows(force: Bool) {
        let visible = inboxFoldersList()
        let desired = SessionGrouper.makeInboxRows(from: visible,
                                                   collapsedFolderIDs: collapsedFolderIDs)
        let merged = SessionGrouper.mergeInboxRows(current: inboxRows, desired: desired)
        if force || merged.map(\.id) != inboxRows.map(\.id) {
            inboxRows = merged
        }
    }

    private func refreshInboxStats() {
        hasAnySnapshots = !snapshotByID.isEmpty
        hiddenDoneCount = snapshotByID.values.filter {
            WorkStatusResolver.isInactiveInbox($0.workState)
        }.count
        hiddenOlderCount = snapshotByID.values.filter { snap in
            !WorkStatusResolver.isRecentForInbox(snap)
                && !WorkStatusResolver.isInactiveInbox(snap.workState)
        }.count
        inboxSnapshotCountCache = inboxFoldersList().reduce(0) { $0 + $1.snapshots.count }
        inboxFolderCountCache = inboxRows.reduce(into: 0) { count, row in
            if case .folderHeader = row { count += 1 }
        }
    }

    private var inboxSnapshotCountCache = 0
    private var inboxFolderCountCache = 0

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Recompute time-sensitive Working/Done labels without a full disk scan.
    private func scheduleLiveStatusTimer() {
        liveStatusTimer?.invalidate()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshLiveStatuses()
        }
        RunLoop.main.add(t, forMode: .common)
        liveStatusTimer = t
    }

    private func refreshLiveStatuses() {
        guard !cellsByID.isEmpty else { return }
        let snapshotsToResolve = cellsByID.compactMap { id, cell -> (String, SourceSnapshot)? in
            let snap = cell.snapshot
            guard snap.livePid != nil || snap.state == .running || snap.workState.status == .working else {
                return nil
            }
            return (id, snap)
        }
        guard !snapshotsToResolve.isEmpty else {
            refreshLiveSessionsOnly()
            return
        }
        refreshQueue.async { [weak self] in
            let reparsed = self?.changedLiveSnapshots() ?? []
            let resolved = JSONLAccess.sync {
                snapshotsToResolve.compactMap { id, snap -> (String, Date?, SourceSnapshot)? in
                    let live = WorkStatusResolver.resolveLive(snap)
                    guard live != snap.workState else { return nil }
                    var next = snap
                    next.workState = live
                    return (id, snap.updatedAt, next)
                }
            }
            guard !resolved.isEmpty || !reparsed.isEmpty else { return }
            DispatchQueue.main.async {
                if !reparsed.isEmpty {
                    OverlayLog.write("live poll parsed updates=\(reparsed.count) statuses=\(Self.statusSummary(reparsed))")
                    self?.applyHotUpdates(reparsed)
                }
                self?.applyLiveStatusUpdates(resolved)
            }
        }
    }

    private func changedLiveSnapshots() -> [SourceSnapshot] {
        JSONLAccess.sync {
            var updates: [SourceSnapshot] = []
            for session in LiveAgents.liveSessions() {
                guard let mtime = modificationDate(path: session.jsonlPath) else { continue }
                if liveJSONLMtimes[session.jsonlPath] == mtime { continue }
                liveJSONLMtimes[session.jsonlPath] = mtime
                guard let snap = SessionSnapshotBuilder.snapshot(for: session) else { continue }
                updates.append(Self.snapshotWithLiveWorkState(snap))
            }
            return updates
        }
    }

    private func applyLiveStatusUpdates(_ updates: [(String, Date?, SourceSnapshot)]) {
        var txn = Transaction()
        txn.disablesAnimations = true
        var applied = false
        withTransaction(txn) {
            for (id, baseUpdatedAt, next) in updates {
                guard let cell = cellsByID[id] else { continue }
                guard cell.snapshot.updatedAt == baseUpdatedAt else {
                    OverlayLog.write("live status skip stale id=\(id) captured=\(String(describing: baseUpdatedAt)) current=\(String(describing: cell.snapshot.updatedAt))")
                    continue
                }
                let old = cell.snapshot.workState
                let oldUpdatedAt = cell.snapshot.updatedAt
                cell.apply(next)
                snapshotByID[id] = cell.snapshot
                if old.status != cell.snapshot.workState.status || oldUpdatedAt != cell.snapshot.updatedAt {
                    applied = true
                }
                if old != cell.snapshot.workState {
                    OverlayLog.write("live status apply id=\(id) status=\(old.status.rawValue)->\(cell.snapshot.workState.status.rawValue)")
                }
            }
        }
        if applied {
            SessionStateStore.save(snapshots: allSnapshots)
        }
    }

    private static func snapshotWithLiveWorkState(_ snap: SourceSnapshot) -> SourceSnapshot {
        var next = SourceSnapshot.withStructuralDerivedFields(snap)
        next.workState = WorkStatusResolver.resolveLive(next)
        return next
    }

    private static func statusSummary(_ snapshots: [SourceSnapshot]) -> String {
        snapshots.map { "\($0.badge):\($0.workState.status.rawValue)" }
            .joined(separator: ",")
    }

    private func modificationDate(path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    private static func preferredPollInterval(for snapshots: [SourceSnapshot]) -> TimeInterval {
        let active = snapshots.contains { $0.state == .running || $0.livePid != nil }
        return active ? 5.0 : 15.0
    }

    func workState(for snap: SourceSnapshot) -> WorkState {
        snap.workState
    }

    private func inboxFoldersList() -> [SessionFolder] {
        SessionGrouper.inboxFolders(from: folders,
                                     showInactive: showInactiveSessions,
                                     showOlder: showOlderSessions)
    }

    var inboxSnapshotCount: Int { inboxSnapshotCountCache }

    var inboxFolderCount: Int { inboxFolderCountCache }

    func isInboxVisible(_ snap: SourceSnapshot) -> Bool {
        WorkStatusResolver.isVisibleInInbox(
            snap,
            showInactive: showInactiveSessions,
            showOlder: showOlderSessions
        )
    }

    private func maintainSelection(preferredID: String?) {
        if let id = selectedID {
            if id.hasPrefix("folder:") {
                if inboxFoldersList().contains(where: { $0.selectionID == id }) {
                    return
                }
            } else if selectedSnapshot != nil {
                return
            }
        }
        selectedID = preferredID
    }

    func setShowInactiveSessions(_ value: Bool) {
        guard showInactiveSessions != value else { return }
        showInactiveSessions = value
        rebuildInboxRows(force: true)
        refreshInboxStats()
        maintainSelection(preferredID: SessionGrouper.preferredSelectionID(
            snapshots: snapshots,
            showInactive: value,
            showOlder: showOlderSessions
        ))
    }

    func setShowOlderSessions(_ value: Bool) {
        guard showOlderSessions != value else { return }
        showOlderSessions = value
        rebuildInboxRows(force: true)
        refreshInboxStats()
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
        if snap.tool == "Cursor", let brief = Summarizer.structuredEvidenceBrief(for: snap) {
            return brief
        }
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
            if let task = snap.currentTask, !task.isEmpty {
                parts.append("Goal: \(SourceSnapshot.compactLine(task, limit: 120, maxWords: 18, firstSentence: false)).")
            } else if snap.activityLine != "—" {
                parts.append("Latest: \(snap.activityLine).")
            } else if let goal = goal, !goal.isEmpty {
                parts.append("Goal: \(SourceSnapshot.compactLine(goal, limit: 120, maxWords: 18, firstSentence: false)).")
            }
            return SourceSnapshot.normalizeBrief(parts.joined(separator: " "))
        }
        return Summarizer.structuralFallback(context: ctx, openingGoal: goal)
    }

    private func kickoffSummaryIfNeeded(for snap: SourceSnapshot) {
        guard let path = snap.jsonlPath, let mtime = snap.updatedAt else { return }
        let id = snap.id

        guard Summarizer.shouldSummarize(tool: snap.tool, jsonlPath: path) else {
            if let brief = Self.deterministicBrief(for: snap) {
                let normalized = SourceSnapshot.normalizeBrief(brief)
                if summaries[id] != normalized { summaries[id] = normalized }
            }
            return
        }

        if lastSummaryMtime[id] == mtime { return }
        lastSummaryMtime[id] = mtime
        kickoffSummary(for: snap, mtime: mtime)
    }

    private func kickoffSummary(for snap: SourceSnapshot, mtime: Date) {
        let id = snap.id
        let ctx = summaryContext(for: snap)
        let cached = Summarizer.shared.summary(
            forJSONL: snap.jsonlPath!,
            mtime: mtime,
            context: ctx,
            onUpdate: { [weak self] text in
                DispatchQueue.main.async {
                    self?.summaries[id] = SourceSnapshot.normalizeBrief(text)
                }
            }
        )
        if let cached = cached {
            let normalized = SourceSnapshot.normalizeBrief(cached)
            if summaries[id] != normalized { summaries[id] = normalized }
        }
    }

    var selectedSnapshot: SourceSnapshot? {
        guard let id = selectedID else { return nil }
        return snapshot(id: id)
    }

    var selectedFolder: SessionFolder? {
        guard let id = selectedID, id.hasPrefix("folder:") else { return nil }
        if let inbox = inboxFoldersList().first(where: { $0.selectionID == id }) {
            return inbox
        }
        return folders.first { $0.selectionID == id }
    }

    func requestSummaryForSelection() {
        guard let snap = selectedSnapshot else { return }
        kickoffSummaryIfNeeded(for: snap)
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
        guard var snap = snapshotByID[snapshotID] else { return }
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
        guard snap != snapshotByID[snapshotID] else { return }
        cellsByID[snapshotID]?.apply(snap)
        snapshotByID[snapshotID] = snap
        if let index = snapshots.firstIndex(where: { $0.id == snapshotID }) {
            snapshots[index] = snap
        }
        syncStableFoldersFromSnapshots()
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
        rebuildInboxRows(force: true)
    }
}
