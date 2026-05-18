import Foundation

enum WorkStatus: String, Equatable {
    case needsYou = "Needs you"
    case testsFailed = "Tests failed"
    case stuck = "Stuck"
    case risky = "Risky"
    case ready = "Ready"
    case working = "Working"
    case done = "Done"
}

struct WorkState: Equatable {
    let status: WorkStatus
    let reason: String
    let nextAction: String
    let rank: Int

    var line: String {
        reason.isEmpty ? nextAction : reason
    }
}

enum WorkStatusResolver {
    static func resolve(_ snap: SourceSnapshot) -> WorkState {
        let text = searchableText(snap)
        let codeChanged = hasCodeChanges(snap)
        let testsPassed = hasPassedTestSignal(text)
        let testsFailed = hasFailedTestSignal(text)
        let blocked = blockedReason(text)

        if let blocked {
            return WorkState(status: .needsYou,
                             reason: blocked,
                             nextAction: "Jump back",
                             rank: 0)
        }

        if snap.state == .awaiting {
            return WorkState(status: .needsYou,
                             reason: "waiting for your reply",
                             nextAction: "Jump back",
                             rank: 0)
        }

        if testsFailed {
            return WorkState(status: .testsFailed,
                             reason: "test or CI failure detected",
                             nextAction: "Inspect failure",
                             rank: 1)
        }

        if isStuck(snap, text: text) {
            return WorkState(status: .stuck,
                             reason: stuckReason(snap, text: text),
                             nextAction: "Jump back",
                             rank: 2)
        }

        if codeChanged && testsPassed {
            return WorkState(status: .ready,
                             reason: changeSummary(snap, suffix: "tests passed"),
                             nextAction: "Review diff",
                             rank: 4)
        }

        if codeChanged {
            return WorkState(status: .risky,
                             reason: changeSummary(snap, suffix: "no test evidence"),
                             nextAction: "Run tests",
                             rank: 3)
        }

        if snap.state == .running || snap.livePid != nil {
            return WorkState(status: .working,
                             reason: workingReason(snap),
                             nextAction: "Watch",
                             rank: 5)
        }

        if snap.state == .stale {
            return WorkState(status: .done,
                             reason: "stale session",
                             nextAction: "Ignore",
                             rank: 7)
        }

        return WorkState(status: .done,
                         reason: informationalReason(snap),
                         nextAction: "Read summary",
                         rank: 6)
    }

    static func shouldDisplay(_ snap: SourceSnapshot) -> Bool {
        !isHelperNoise(snap)
    }

    static func sort(_ a: SourceSnapshot, _ b: SourceSnapshot) -> Bool {
        let aw = resolve(a)
        let bw = resolve(b)
        if aw.rank != bw.rank { return aw.rank < bw.rank }
        let ad = a.updatedAt ?? .distantPast
        let bd = b.updatedAt ?? .distantPast
        if ad != bd { return ad > bd }
        return a.id < b.id
    }

    static func hasCodeChanges(_ snap: SourceSnapshot) -> Bool {
        if !snap.filesEdited.isEmpty || !snap.fileChanges.isEmpty { return true }
        if snap.linesAdded > 0 || snap.linesRemoved > 0 { return true }
        if let dirty = snap.dirtyCount, dirty > 0 { return true }
        return false
    }

    private static func searchableText(_ snap: SourceSnapshot) -> String {
        [
            snap.currentTask,
            snap.lastTool,
            snap.lastText,
            snap.note,
            snap.filesEdited.joined(separator: " "),
            snap.fileChanges.map(\.path).joined(separator: " "),
            snap.toolCallCounts.keys.joined(separator: " "),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()
    }

    private static func isHelperNoise(_ snap: SourceSnapshot) -> Bool {
        let text = searchableText(snap)
        if text.contains("summarize this coding-assistant session") { return true }
        if text.contains("summarize this claude code session transcript") { return true }
        if text.contains("summarise this session") { return true }
        if text.contains("uses your installed `claude -p` or `codex exec`") { return true }
        if snap.tool == "Codex", text.contains("codex exec"), text.contains("summarize") { return true }
        return false
    }

    private static func blockedReason(_ text: String) -> String? {
        if text.contains("out of extra usage") || text.contains("out of usage") {
            return "usage limit reached"
        }
        if text.contains("does not have access") || text.contains("authentication_failed") {
            return "login required"
        }
        if text.contains("please run /login") {
            return "login required"
        }
        if text.contains("waiting for approval") || text.contains("approval to run") {
            return "waiting for approval"
        }
        if text.contains("permission denied") {
            return "permission denied"
        }
        return nil
    }

    private static func hasFailedTestSignal(_ text: String) -> Bool {
        guard containsTestSignal(text) else { return false }
        return text.contains("failed") ||
            text.contains("failure") ||
            text.contains("exit code 1") ||
            text.contains("exit status 1") ||
            text.contains("conclusion: failure") ||
            text.contains("\"conclusion\":\"failure\"")
    }

    private static func hasPassedTestSignal(_ text: String) -> Bool {
        guard containsTestSignal(text) else { return false }
        return text.contains("passed") ||
            text.contains("succeeded") ||
            text.contains("success") ||
            text.contains("green") ||
            text.contains("\"conclusion\":\"success\"")
    }

    private static func containsTestSignal(_ text: String) -> Bool {
        let needles = [
            "pytest", "npm test", "npm run test", "yarn test", "swift test",
            "go test", "cargo test", "vitest", "jest", "gh run", "github action",
            "workflow", "ci"
        ]
        return needles.contains { text.contains($0) }
    }

    private static func isStuck(_ snap: SourceSnapshot, text: String) -> Bool {
        if text.contains("same error") || text.contains("repeated") { return true }
        if snap.fileChanges.contains(where: { $0.retryCount >= 3 }) { return true }
        if snap.state == .stale && snap.tasksInProgress > 0 { return true }
        return false
    }

    private static func stuckReason(_ snap: SourceSnapshot, text: String) -> String {
        if text.contains("same error") { return "same error repeated" }
        if let retry = snap.fileChanges.map(\.retryCount).max(), retry >= 3 {
            return "\(retry + 1) edits to the same file"
        }
        return "stale with work in progress"
    }

    private static func changeSummary(_ snap: SourceSnapshot, suffix: String) -> String {
        let fileCount = max(snap.fileChanges.count, snap.filesEdited.count)
        let dirty = snap.dirtyCount ?? 0
        let count = fileCount > 0 ? fileCount : dirty
        let noun = count == 1 ? "file" : "files"
        if count > 0 {
            return "\(count) \(noun) changed - \(suffix)"
        }
        return "changes detected - \(suffix)"
    }

    private static func workingReason(_ snap: SourceSnapshot) -> String {
        if let task = snap.currentTask, !task.isEmpty { return task }
        if let tool = snap.lastTool, !tool.isEmpty { return tool }
        return "agent is active"
    }

    private static func informationalReason(_ snap: SourceSnapshot) -> String {
        if let text = snap.lastText, !text.isEmpty { return "answer complete" }
        if let note = snap.note, !note.isEmpty { return note }
        return "no code changes"
    }
}
