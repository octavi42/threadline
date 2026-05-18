import AppKit
import Foundation
import Combine

enum SourceState: String, Equatable {
    case running    // assistant turn in progress
    case awaiting   // user input expected
    case idle       // recently finished
    case error      // approval pending / error
    case stale      // not updated for a while
    case none       // no session found
}

struct TaskItem: Equatable, Identifiable {
    var id: String { content }
    let content: String
    let status: String   // "in_progress" | "completed" | "pending"
}

/// A single edit operation the agent performed on a file.
struct FileEditOp: Equatable, Identifiable {
    /// Monotonic sequence number assigned at extraction time for stable identity.
    let seq: Int
    let tool: String       // "Edit" | "Write" | "MultiEdit" | "apply_patch"
    let timestamp: String
    var oldText: String = ""
    var newText: String = ""
    var patchText: String = ""
    var note: String = ""
    /// Pre-truncation line counts so badges stay accurate even when display
    /// text is capped at 4KB.
    var rawLinesAdded: Int = 0
    var rawLinesRemoved: Int = 0
    var patchDisplay: DiffDisplay = .empty
    var oldTextDisplay: DiffDisplay = .empty
    var newTextDisplay: DiffDisplay = .empty

    var id: String { "\(seq)" }
}

/// All edits the agent made to one file, with surrounding context.
struct FileChangeGroup: Equatable, Identifiable {
    var id: String { path }
    let path: String
    var edits: [FileEditOp] = []
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    var retryCount: Int { max(0, edits.count - 1) }
}

struct SourceSnapshot: Identifiable, Equatable {
    let id: String              // "claude:/Users/foo/proj" — unique per session
    let tool: String            // "Claude" | "Codex" | "Cursor"
    let badge: String           // "CLD"   | "CDX"   | "CUR"
    var state: SourceState = .idle
    var cwd: String?
    var model: String?
    var currentTask: String?
    var lastTool: String?
    var lastText: String?
    var branch: String?
    var dirtyCount: Int?
    var contextPercent: Double?
    var costUSD: Double?
    var updatedAt: Date?
    var note: String?

    // Phase 2 fields — populated when available; nil otherwise.
    var tasks: [TaskItem] = []
    var filesEdited: [String] = []        // distinct, in order seen
    var toolCallCounts: [String: Int] = [:]
    /// Estimated tokens consumed per tool (sum of input + result bytes / 4).
    var toolTokenEstimate: [String: Int] = [:]
    /// Lines the agent has added across all Edit/Write/MultiEdit calls.
    var linesAdded: Int = 0
    /// Lines the agent has removed across Edit/MultiEdit `old_string` payloads.
    var linesRemoved: Int = 0
    /// Per-file edit operations extracted from the session JSONL.
    var fileChanges: [FileChangeGroup] = []
    var userTurns: Int = 0
    var assistantTurns: Int = 0
    var sessionStart: Date?               // first record's timestamp
    /// The session's underlying JSONL path. Used by the summarizer.
    var jsonlPath: String?
    /// Live process id for this agent when it is currently running.
    var livePid: pid_t?
    /// TTY for the shell that launched this agent, when the prompt hook has
    /// reported it. Used for terminal-specific exact-tab focusing.
    var tty: String?
    var terminalBundleID: String?
    var terminalPID: pid_t?
    var terminalSurfaceID: String?
    var terminalWindowID: String?
    var terminalTabID: String?
    /// Resolved once when the snapshot is built — used for inbox sort and UI.
    var workState: WorkState = WorkState(status: .done, reason: "", nextAction: "", rank: 6)
    var tasksDone: Int = 0
    var tasksInProgress: Int = 0
    var tasksPending: Int = 0

    var projectName: String {
        guard let cwd = cwd, !cwd.isEmpty else { return "—" }
        return (cwd as NSString).lastPathComponent
    }

    var displayCwd: String {
        guard let cwd = cwd else { return "—" }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    /// Single-line summary for the agents list row.
    var activityLine: String {
        if let task = currentTask, !task.isEmpty { return SourceSnapshot.compactLine(task) }
        if let t = lastTool, !t.isEmpty { return t }
        if let txt = lastText, !txt.isEmpty {
            return SourceSnapshot.compactLine(txt)
        }
        return note.map { SourceSnapshot.compactLine($0) } ?? "—"
    }

    /// Right-side compact metrics for the details pane.
    var metricsLine: String {
        var parts: [String] = []
        if let m = model           { parts.append(shortModel(m)) }
        if let b = branch {
            parts.append(dirtyCount.map { $0 > 0 ? "\(b)+\($0)" : b } ?? b)
        }
        if let p = contextPercent  { parts.append(String(format: "%.0f%% ctx", p * 100)) }
        if let c = costUSD, c > 0  { parts.append(String(format: "$%.2f", c)) }
        return parts.joined(separator: " · ")
    }

    /// One-line sidebar headline from a session brief.
    static func briefHeadline(_ brief: String) -> String {
        compactLine(brief, limit: 96, maxWords: 16, firstSentence: true)
    }

    /// Multi-sentence session brief for the Overview tab.
    static func normalizeBrief(_ text: String) -> String {
        var line = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Keep up to two sentences when the model returns a wall of text.
        var sentences: [String] = []
        var rest = line
        while !rest.isEmpty, sentences.count < 2 {
            if let range = rest.range(of: #"[.!?]\s+"#, options: .regularExpression) {
                let end = range.upperBound
                let chunk = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { sentences.append(chunk) }
                rest = String(rest[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                sentences.append(rest)
                break
            }
        }
        if !sentences.isEmpty {
            line = sentences.joined(separator: " ")
        }

        let maxWords = 50
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        if words.count > maxWords {
            line = words.prefix(maxWords).joined(separator: " ") + "..."
        }

        let limit = 320
        guard line.count > limit else { return line }
        let cutoff = line.index(line.startIndex, offsetBy: max(0, limit - 1))
        let prefix = line[..<cutoff]
        if let space = prefix.lastIndex(of: " "), space > line.startIndex {
            return String(prefix[..<space]) + "..."
        }
        return String(prefix) + "..."
    }

    /// Deprecated alias — sidebar uses `briefHeadline` on stored briefs.
    static func normalizeSummary(_ text: String) -> String {
        briefHeadline(text)
    }

    static func compactLine(_ text: String,
                            limit: Int = 96,
                            maxWords: Int? = nil,
                            firstSentence: Bool = true) -> String {
        var line = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if firstSentence, let end = line.firstIndex(where: { ".!?".contains($0) }) {
            let sentenceEnd = line.index(after: end)
            let trimmed = String(line[..<sentenceEnd])
            if trimmed.count >= 24 { line = trimmed }
        }

        if let maxWords = maxWords {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            if words.count > maxWords {
                line = words.prefix(maxWords).joined(separator: " ") + "..."
            }
        }

        guard line.count > limit else { return line }
        let cutoff = line.index(line.startIndex, offsetBy: max(0, limit - 1))
        let prefix = line[..<cutoff]
        if let space = prefix.lastIndex(of: " "), space > line.startIndex {
            return String(prefix[..<space]) + "..."
        }
        return String(prefix) + "..."
    }

    /// Short token-count label: "412", "4.2K", "120K", "1.2M".
    static func formatTokens(_ n: Int) -> String {
        if n < 1_000        { return "\(n)" }
        if n < 10_000       { return String(format: "%.1fK", Double(n) / 1_000) }
        if n < 1_000_000    { return "\(n / 1_000)K" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    var timeAgoShort: String {
        guard let t = updatedAt else { return "—" }
        let s = Int(-t.timeIntervalSinceNow)
        if s < 5            { return "now" }
        if s < 60           { return "\(s)s" }
        if s < 3600         { return "\(s / 60)m" }
        if s < 86_400       { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    /// $/min averaged over the session. nil if duration < 30s or cost is nil.
    var costBurnPerMin: Double? {
        guard let cost = costUSD, let start = sessionStart else { return nil }
        let mins = -start.timeIntervalSinceNow / 60.0
        if mins < 0.5 { return nil }
        return cost / mins
    }

    /// Time remaining in the current 5-hour Claude billing block (only
    /// meaningful for Claude). nil if no session start known.
    var blockRemaining: TimeInterval? {
        guard tool == "Claude", let start = sessionStart else { return nil }
        let blockEnd = start.addingTimeInterval(5 * 3600)
        let remaining = blockEnd.timeIntervalSinceNow
        return remaining > 0 ? remaining : 0
    }

    /// Formatted "Hh Mm" for the block-remaining timer.
    var blockRemainingFormatted: String? {
        guard let r = blockRemaining else { return nil }
        let h = Int(r) / 3600
        let m = (Int(r) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func shortModel(_ m: String) -> String {
        let lower = m.lowercased()
        if let r = lower.range(of: "claude-") { return String(lower[r.upperBound...]) }
        if let r = lower.range(of: "anthropic/") { return String(lower[r.upperBound...]) }
        return lower
    }
}

struct FolderStats: Equatable {
    let running: Int
    let awaiting: Int
    let tasksDone: Int
    let taskCount: Int
    let uniqueFileCount: Int
    let toolsSummary: String
}

struct SessionFolder: Identifiable, Equatable {
    let cwd: String
    var snapshots: [SourceSnapshot]
    var stats: FolderStats = FolderStats(running: 0, awaiting: 0, tasksDone: 0,
                                         taskCount: 0, uniqueFileCount: 0, toolsSummary: "")

    var id: String { cwd }
    var selectionID: String { "folder:\(cwd)" }

    var name: String {
        (cwd as NSString).lastPathComponent
    }

    var displayCwd: String {
        (cwd as NSString).abbreviatingWithTildeInPath
    }

    var latestSnapshot: SourceSnapshot? {
        snapshots.first
    }

    func filesSummary() -> FolderFilesSummary {
        let files = mergedFiles()
        return FolderFilesSummary(
            fileCount: files.count,
            linesAdded: files.reduce(0) { $0 + $1.linesAdded },
            linesRemoved: files.reduce(0) { $0 + $1.linesRemoved }
        )
    }

    /// Paths touched by any session in this project, merged and ranked by churn.
    func mergedFiles() -> [FolderMergedFile] {
        struct Acc {
            var edits: [MergedFileEdit] = []
            var linesAdded = 0
            var linesRemoved = 0
            var tools: Set<String> = []
            var snapshotIDs: Set<String> = []
        }

        var byPath: [String: Acc] = [:]

        for snap in snapshots {
            for group in snap.fileChanges {
                let path = group.path
                var acc = byPath[path] ?? Acc()
                for op in group.edits {
                    acc.edits.append(MergedFileEdit(
                        id: "\(snap.id):\(op.seq)",
                        sourceSnapshotID: snap.id,
                        sourceTool: snap.tool,
                        op: op
                    ))
                }
                acc.linesAdded += group.linesAdded
                acc.linesRemoved += group.linesRemoved
                acc.tools.insert(snap.tool)
                acc.snapshotIDs.insert(snap.id)
                byPath[path] = acc
            }
            for path in snap.filesEdited {
                var acc = byPath[path] ?? Acc()
                acc.tools.insert(snap.tool)
                acc.snapshotIDs.insert(snap.id)
                byPath[path] = acc
            }
        }

        return byPath.map { path, acc in
            let sortedEdits = acc.edits.sorted {
                if $0.sourceSnapshotID != $1.sourceSnapshotID {
                    return $0.sourceSnapshotID < $1.sourceSnapshotID
                }
                return $0.op.seq < $1.op.seq
            }
            return FolderMergedFile(
                path: path,
                linesAdded: acc.linesAdded,
                linesRemoved: acc.linesRemoved,
                editCount: sortedEdits.count,
                tools: acc.tools.sorted(),
                edits: sortedEdits,
                sourceSnapshotIDs: acc.snapshotIDs.sorted()
            )
        }
        .sorted { a, b in
            if a.churn != b.churn { return a.churn > b.churn }
            if a.editCount != b.editCount { return a.editCount > b.editCount }
            return a.path < b.path
        }
    }
}

struct FolderFilesSummary: Equatable {
    let fileCount: Int
    let linesAdded: Int
    let linesRemoved: Int
}

/// One edit op in a project-level merge — composite id spans sessions.
struct MergedFileEdit: Identifiable, Equatable {
    let id: String
    let sourceSnapshotID: String
    let sourceTool: String
    let op: FileEditOp
}

/// One file row in the project-level files digest.
struct FolderMergedFile: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let linesAdded: Int
    let linesRemoved: Int
    let editCount: Int
    let tools: [String]
    let edits: [MergedFileEdit]
    let sourceSnapshotIDs: [String]

    var churn: Int { linesAdded + linesRemoved }

    var toolsLabel: String {
        guard !tools.isEmpty else { return "" }
        if tools.count <= 2 { return tools.joined(separator: ", ") }
        return "\(tools[0]), \(tools[1]) +\(tools.count - 2)"
    }

    var hasDiffContent: Bool { !edits.isEmpty }
}

final class SessionModel: ObservableObject {
    @Published var snapshots: [SourceSnapshot] = []
    @Published var folders: [SessionFolder] = []
    @Published var selectedID: String?
    /// LLM summaries keyed by snapshot id (= absolute JSONL path with prefix).
    /// Lands asynchronously when the Summarizer completes a fetch.
    @Published var summaries: [String: String] = [:]
    /// LLM-classified work state keyed by snapshot id. Falls back to
    /// WorkStatusResolver until the classifier lands.
    @Published var workStates: [String: WorkState] = [:]
    /// File paths the user has expanded in the Files tab. Stored here so the
    /// 3-second refresh cycle doesn't reset the expansion state.
    @Published var expandedFiles: Set<String> = []
    /// Project folders the user collapsed in the agents sidebar. Absence means
    /// expanded; stored on the model so the 3-second refresh does not reset it.
    @Published var collapsedFolderIDs: Set<String> = []
    /// When false, hide `Done` sessions so the sidebar is an action inbox.
    @Published var showInactiveSessions = false
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

        let all = buildSnapshots()
        let folders = Self.makeFolders(from: all)
        let pollInterval = Self.preferredPollInterval(for: all)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, generation == self.refreshGeneration else { return }
            self.applyRefresh(snapshots: all, folders: folders, pollInterval: pollInterval)
        }
    }

    private func applyRefresh(snapshots all: [SourceSnapshot],
                              folders: [SessionFolder],
                              pollInterval: TimeInterval) {
        if all != snapshots { self.snapshots = all }
        if folders != self.folders {
            self.folders = folders
            pruneCollapsedFolders(visible: folders.map(\.id))
        }
        let preferred = Self.preferredSelectionID(
            snapshots: all,
            workStates: workStates,
            showInactive: showInactiveSessions
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

    private func buildSnapshots() -> [SourceSnapshot] {
        var all: [SourceSnapshot] = []

        for session in LiveAgents.liveSessions() {
            var snap: SourceSnapshot?
            switch session.tool {
            case "Claude": snap = ClaudeSource.snapshot(forJSONL: session.jsonlPath)
            case "Codex":  snap = CodexSource.snapshot(forJSONL: session.jsonlPath)
            default:       snap = nil
            }
            if var s = snap {
                s.livePid = session.pid
                if let shell = ShellRegistry.shared.shell(forDescendant: session.pid) {
                    s.tty = shell.tty
                    s.terminalBundleID = shell.terminal?.bundleID
                    s.terminalPID = shell.terminal?.appPID
                    s.terminalSurfaceID = shell.terminal?.surfaceID
                    s.terminalWindowID = shell.terminal?.windowID
                    s.terminalTabID = shell.terminal?.tabID
                } else if let terminal = TerminalIdentityResolver.resolve(agentPid: session.pid,
                                                                          cwd: s.cwd) {
                    s.tty = terminal.tty
                    s.terminalBundleID = terminal.bundleID
                    s.terminalPID = terminal.appPID
                    s.terminalSurfaceID = terminal.surfaceID
                    s.terminalWindowID = terminal.windowID
                    s.terminalTabID = terminal.tabID
                }
                all.append(SourceSnapshot.withDerivedFields(s))
            }
        }

        if LiveAgents.cursorRunning {
            let cursorCutoff = Date().addingTimeInterval(-30 * 60)
            all.append(contentsOf: CursorSource.readAll(since: cursorCutoff)
                .map(SourceSnapshot.withDerivedFields))
        }

        all = all.map { snap in
            var s = snap
            if s.state == .stale { s.state = .idle }
            return s
        }

        all = all.filter(WorkStatusResolver.shouldDisplay)
        all.sort(by: WorkStatusResolver.sort)
        return all
    }

    private static func makeFolders(from snapshots: [SourceSnapshot]) -> [SessionFolder] {
        let grouped = Dictionary(grouping: snapshots) { snap in
            guard let cwd = snap.cwd, !cwd.isEmpty else { return "Unknown" }
            return (cwd as NSString).standardizingPath
        }
        return grouped.map { cwd, snaps in
            let sorted = snaps.sorted(by: WorkStatusResolver.sort)
            return SessionFolder(cwd: cwd, snapshots: sorted, stats: SessionFolder.makeStats(from: sorted))
        }
        .sorted { a, b in
            WorkStatusResolver.folderSort(a, b, workStates: [:])
        }
    }

    /// Inbox trust labels — deterministic and stable until the session log changes.
    func workState(for snap: SourceSnapshot) -> WorkState {
        snap.workState
    }

    /// Detail pane may use LLM classification when available.
    func detailWorkState(for snap: SourceSnapshot) -> WorkState {
        workStates[snap.id] ?? snap.workState
    }

    /// Folders and sessions for the sidebar trust board (respects `showInactiveSessions`).
    var inboxFolders: [SessionFolder] {
        let mapped: [SessionFolder] = folders.compactMap { folder in
            let visible = folder.visibleSnapshots(
                showInactive: showInactiveSessions,
                workStates: workStates
            )
            guard !visible.isEmpty else { return nil }
            var f = folder
            f.snapshots = visible
            f.stats = SessionFolder.makeStats(from: visible)
            return f
        }
        return mapped.sorted { WorkStatusResolver.folderSort($0, $1, workStates: workStates) }
    }

    var inboxSnapshotCount: Int {
        inboxFolders.reduce(0) { $0 + $1.snapshots.count }
    }

    private static func preferredSelectionID(snapshots: [SourceSnapshot],
                                             workStates: [String: WorkState],
                                             showInactive: Bool) -> String? {
        let visible = showInactive
            ? snapshots
            : snapshots.filter {
                !WorkStatusResolver.isInactiveInbox(workStates[$0.id] ?? $0.workState)
            }
        return visible.first?.id
    }

    private func maintainSelection(preferredID: String?) {
        if let id = selectedID {
            if selectedSnapshot != nil {
                if !showInactiveSessions,
                   let snap = selectedSnapshot,
                   WorkStatusResolver.isInactiveInbox(workState(for: snap)) {
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
        let preferred = Self.preferredSelectionID(
            snapshots: snapshots,
            workStates: workStates,
            showInactive: value
        )
        maintainSelection(preferredID: preferred)
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

    private func kickoffSummary(for snap: SourceSnapshot) {
        guard let path = snap.jsonlPath, let mtime = snap.updatedAt else { return }
        let id = snap.id
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

    private func kickoffWorkClassification(for snap: SourceSnapshot) {
        guard snap.jsonlPath != nil, snap.updatedAt != nil else { return }
        let id = snap.id
        let cached = WorkClassifier.shared.classify(
            snap: snap,
            onUpdate: { [weak self] work in
                self?.workStates[id] = work
            }
        )
        if let cached = cached, workStates[id] != cached {
            workStates[id] = cached
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
        kickoffWorkClassification(for: snap)
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
        selectedID = snap.id
        return true
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
