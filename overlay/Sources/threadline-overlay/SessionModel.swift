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
    var userTurns: Int = 0
    var assistantTurns: Int = 0
    var sessionStart: Date?               // first record's timestamp
    /// The session's underlying JSONL path. Used by the summarizer.
    var jsonlPath: String?

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
        if let task = currentTask, !task.isEmpty { return task }
        if let t = lastTool, !t.isEmpty { return t }
        if let txt = lastText, !txt.isEmpty {
            return txt.replacingOccurrences(of: "\n", with: " ")
        }
        return note ?? "—"
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

    var tasksDone:       Int { tasks.filter { $0.status == "completed"   }.count }
    var tasksInProgress: Int { tasks.filter { $0.status == "in_progress" }.count }
    var tasksPending:    Int { tasks.filter { $0.status == "pending"     }.count }

    private func shortModel(_ m: String) -> String {
        let lower = m.lowercased()
        if let r = lower.range(of: "claude-") { return String(lower[r.upperBound...]) }
        if let r = lower.range(of: "anthropic/") { return String(lower[r.upperBound...]) }
        return lower
    }
}

final class SessionModel: ObservableObject {
    @Published var snapshots: [SourceSnapshot] = []
    @Published var selectedID: String?
    /// LLM summaries keyed by snapshot id (= absolute JSONL path with prefix).
    /// Lands asynchronously when the Summarizer completes a fetch.
    @Published var summaries: [String: String] = [:]
    private var timer: Timer?

    /// Treat anything modified within this window as "active enough to surface".
    let activeWindow: TimeInterval = 7 * 24 * 3600

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        var all: [SourceSnapshot] = []

        // One snapshot per live tab — Claude and Codex are driven directly
        // off LiveAgents.liveSessions(), which maps each live PID to its
        // own JSONL file (per-tab uniqueness).
        for session in LiveAgents.liveSessions() {
            let snap: SourceSnapshot?
            switch session.tool {
            case "Claude": snap = ClaudeSource.snapshot(forJSONL: session.jsonlPath)
            case "Codex":  snap = CodexSource.snapshot(forJSONL: session.jsonlPath)
            default:       snap = nil
            }
            if let s = snap { all.append(s) }
        }

        // Cursor has no per-workspace process, so we surface every workspace
        // whose state.vscdb was touched in the last 30 min and Cursor.app
        // is running.
        if LiveAgents.cursorRunning {
            let cursorCutoff = Date().addingTimeInterval(-30 * 60)
            all.append(contentsOf: CursorSource.readAll(since: cursorCutoff))
        }

        // A live tool process is by definition not stale.
        all = all.map { snap in
            var s = snap
            if s.state == .stale { s.state = .idle }
            return s
        }

        // Most recently active first; running > others within the same time bucket.
        all.sort { a, b in
            let ad = a.updatedAt ?? .distantPast
            let bd = b.updatedAt ?? .distantPast
            if abs(ad.timeIntervalSince(bd)) < 1 {
                return rank(a.state) < rank(b.state)
            }
            return ad > bd
        }
        let firstID = all.first?.id
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.snapshots = all
            if let sel = self.selectedID, all.contains(where: { $0.id == sel }) { return }
            self.selectedID = firstID
        }
    }

    private func rank(_ s: SourceState) -> Int {
        switch s {
        case .running:  return 0
        case .awaiting: return 1
        case .idle:     return 2
        case .error:    return 3
        case .stale:    return 4
        case .none:     return 5
        }
    }

    var selectedSnapshot: SourceSnapshot? {
        guard let id = selectedID else { return nil }
        return snapshots.first { $0.id == id }
    }

    /// Request a summary for the currently-selected snapshot.
    /// Idempotent — cache hits return immediately; async fetches surface via
    /// the @Published `summaries` dict.
    func requestSummaryForSelection() {
        guard let snap = selectedSnapshot,
              let path = snap.jsonlPath,
              let mtime = snap.updatedAt
        else { return }
        let id = snap.id
        if let cached = Summarizer.shared.summary(forJSONL: path,
                                                  mtime: mtime,
                                                  onUpdate: { [weak self] text in
            self?.summaries[id] = text
        }) {
            summaries[id] = cached
        }
    }
}
