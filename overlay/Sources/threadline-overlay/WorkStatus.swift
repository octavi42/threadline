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
    private static let transcriptCacheLock = NSLock()
    private static var transcriptCache: [String: (mtime: Date, text: String?)] = [:]

    /// Snapshot metadata plus recent JSONL transcript text used for tagging.
    static func evidenceText(for snap: SourceSnapshot) -> String {
        var parts = [searchableText(snap)]
        if let path = snap.jsonlPath,
           let tail = transcriptEvidence(fromJSONL: path) {
            parts.append(tail)
        }
        return parts.joined(separator: "\n").lowercased()
    }

    private static let resolveCacheLock = NSLock()
    private static var resolveCache: [String: (mtime: Date, work: WorkState)] = [:]

    /// Stable trust label for a session — recomputes only when the JSONL mtime changes.
    static func resolveStable(_ snap: SourceSnapshot) -> WorkState {
        let mtime = snap.updatedAt ?? .distantPast
        resolveCacheLock.lock()
        if let hit = resolveCache[snap.id], hit.mtime == mtime {
            let work = hit.work
            resolveCacheLock.unlock()
            return work
        }
        resolveCacheLock.unlock()

        let work = resolve(snap)
        resolveCacheLock.lock()
        resolveCache[snap.id] = (mtime, work)
        resolveCacheLock.unlock()
        return work
    }

    static func pruneResolveCache(keeping ids: Set<String>) {
        resolveCacheLock.lock()
        resolveCache = resolveCache.filter { ids.contains($0.key) }
        resolveCacheLock.unlock()
    }

    static func resolve(_ snap: SourceSnapshot) -> WorkState {
        let text = evidenceText(for: snap)
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

        if isZombieSession(snap) {
            return WorkState(status: .done,
                             reason: codeChanged
                                 ? "old session · unverified changes"
                                 : "old session",
                             nextAction: "Ignore",
                             rank: 7)
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

        if isActivelyWorking(snap) {
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

    /// Sessions hidden from the default inbox (completed / informational).
    static func isInactiveInbox(_ work: WorkState) -> Bool {
        work.status == .done
    }

    static func sort(_ a: SourceSnapshot, _ b: SourceSnapshot) -> Bool {
        sortByWork(a.workState, b.workState, a: a, b: b)
    }

    static func sortByWork(_ wa: WorkState, _ wb: WorkState,
                           a: SourceSnapshot, b: SourceSnapshot) -> Bool {
        if wa.rank != wb.rank { return wa.rank < wb.rank }
        let ad = a.updatedAt ?? .distantPast
        let bd = b.updatedAt ?? .distantPast
        if ad != bd { return ad > bd }
        return a.id < b.id
    }

    static func folderSort(_ a: SessionFolder, _ b: SessionFolder,
                           workStates: [String: WorkState]) -> Bool {
        let aw = a.trustSummary(workStates: workStates).worstRank
        let bw = b.trustSummary(workStates: workStates).worstRank
        if aw != bw { return aw < bw }
        let ad = a.latestSnapshot?.updatedAt ?? .distantPast
        let bd = b.latestSnapshot?.updatedAt ?? .distantPast
        if ad != bd { return ad > bd }
        return a.cwd < b.cwd
    }

    static func hasCodeChanges(_ snap: SourceSnapshot) -> Bool {
        if !snap.filesEdited.isEmpty || !snap.fileChanges.isEmpty { return true }
        if snap.linesAdded > 0 || snap.linesRemoved > 0 { return true }
        if let dirty = snap.dirtyCount, dirty > 0 { return true }
        return false
    }

    static func isActivelyWorking(_ snap: SourceSnapshot, now: Date = Date()) -> Bool {
        if snap.state == .running { return true }
        guard snap.livePid != nil, let updatedAt = snap.updatedAt else { return false }
        // Live CLI process but idle: only "working" if the log changed very recently.
        return now.timeIntervalSince(updatedAt) < 30
    }

    // MARK: - evidence

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
    }

    /// Human-readable lines from the JSONL tail (messages + test-related tool output).
    private static func transcriptEvidence(fromJSONL path: String,
                                           maxBytes: Int = 96 * 1024) -> String? {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else {
            return parseTranscriptEvidence(fromJSONL: path, maxBytes: maxBytes)
        }

        transcriptCacheLock.lock()
        if let hit = transcriptCache[path], hit.mtime == mtime {
            let cached = hit.text
            transcriptCacheLock.unlock()
            return cached
        }
        transcriptCacheLock.unlock()

        let parsed = parseTranscriptEvidence(fromJSONL: path, maxBytes: maxBytes)
        transcriptCacheLock.lock()
        transcriptCache[path] = (mtime, parsed)
        transcriptCacheLock.unlock()
        return parsed
    }

    private static func parseTranscriptEvidence(fromJSONL path: String,
                                                maxBytes: Int) -> String? {
        guard let tail = tailOfFile(path: path, maxBytes: maxBytes) else { return nil }
        var snippets: [String] = []

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let message = obj["message"] as? [String: Any] {
                appendClaudeMessage(message, into: &snippets)
                continue
            }

            let type = obj["type"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if type == "event_msg" {
                switch payload["type"] as? String {
                case "agent_message", "user_message":
                    if let msg = payload["message"] as? String, !msg.isEmpty {
                        snippets.append(msg)
                    }
                default:
                    break
                }
            } else if type == "response_item" {
                switch payload["type"] as? String {
                case "message":
                    let content = payload["content"] as? [[String: Any]] ?? []
                    for block in content {
                        for key in ["text", "input_text", "output_text"] {
                            if let t = block[key] as? String, !t.isEmpty {
                                snippets.append(t)
                            }
                        }
                    }
                case "function_call_output":
                    if let output = payload["output"] as? String,
                       transcriptOutputIsRelevant(output) {
                        snippets.append(output)
                    }
                default:
                    break
                }
            }
        }

        guard !snippets.isEmpty else { return nil }
        return snippets.joined(separator: "\n")
    }

    private static func appendClaudeMessage(_ message: [String: Any],
                                            into snippets: inout [String]) {
        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "text",
                   let t = block["text"] as? String,
                   !t.isEmpty, !t.hasPrefix("<") {
                    snippets.append(t)
                }
            }
        } else if let s = message["content"] as? String, !s.isEmpty {
            snippets.append(s)
        }
    }

    private static func transcriptOutputIsRelevant(_ output: String) -> Bool {
        let lower = output.lowercased()
        let needles = [
            "swift test", "pytest", "npm test", "yarn test", "cargo test",
            "vitest", "jest", "go test", "exit code", "exit status",
            "tests pass", "test pass", "tests failed", "test failed",
            "0 failures", "conclusion", "github action", "workflow run",
        ]
        return needles.contains { lower.contains($0) }
    }

    // MARK: - signals

    private static func isHelperNoise(_ snap: SourceSnapshot) -> Bool {
        let text = searchableText(snap).lowercased()
        if text.contains("summarize this coding-assistant session") { return true }
        if text.contains("summarize this claude code session transcript") { return true }
        if text.contains("summarise this session") { return true }
        if text.contains("classify the session from stdin") { return true }
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
        let phrases = [
            "pytest failed", "npm test failed", "npm run test failed",
            "yarn test failed", "swift test failed", "go test failed",
            "cargo test failed", "vitest failed", "jest failed",
            "\"conclusion\":\"failure\"", "\"conclusion\": \"failure\"",
        ]
        if phrases.contains(where: { text.contains($0) }) { return true }
        return matchesNonZeroExitFailure(text)
    }

    /// Match exit code/status 1 without false positives like "exit code 10".
    private static func matchesNonZeroExitFailure(_ text: String) -> Bool {
        let patterns = [
            #"exit\s+code\s*[:=]?\s*1\b"#,
            #"exit\s+status\s*[:=]?\s*1\b"#,
            #"exited\s+with\s+1\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func hasPassedTestSignal(_ text: String) -> Bool {
        let phrases = [
            "pytest passed", "npm test passed", "npm run test passed",
            "yarn test passed", "swift test passed", "go test passed",
            "cargo test passed", "vitest passed", "jest passed",
            "tests passed", "test passed", "all tests pass", "all swift tests pass",
            "`swift test` passes", "swift test passes",
            "0 failures (0 unexpected)", "0 failures(0 unexpected)",
            "test suite 'all tests' passed", "test suite \"all tests\" passed",
            "build complete",
            "\"conclusion\":\"success\"", "\"conclusion\": \"success\"",
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func isStuck(_ snap: SourceSnapshot, text: String) -> Bool {
        if stuckLoop(from: snap, text: text) != nil { return true }
        if hasRetryLoopSignal(text) { return true }
        if snap.state == .stale && snap.tasksInProgress > 0 { return true }
        return false
    }

    private static func stuckLoop(from snap: SourceSnapshot, text: String) -> StuckLoopDetector.Result? {
        if let path = snap.jsonlPath, let loop = StuckLoopDetector.analyze(jsonlPath: path) {
            return loop
        }
        return StuckLoopDetector.analyze(text: text)
    }

    private static func hasRetryLoopSignal(_ text: String) -> Bool {
        if text.contains("same error") { return true }
        let phrases = [
            "same error repeated",
            "same error again",
            "retry loop",
            "keeps failing with the same",
            "failed again with the same",
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func stuckReason(_ snap: SourceSnapshot, text: String) -> String {
        if let loop = stuckLoop(from: snap, text: text) {
            return StuckLoopDetector.reason(for: loop)
        }
        if text.contains("same error") || hasRetryLoopSignal(text) {
            return "same error repeated"
        }
        return "stale with work in progress"
    }

    /// Live process with no recent JSONL activity — deprioritize over Risky.
    private static func isZombieSession(_ snap: SourceSnapshot, now: Date = Date()) -> Bool {
        guard snap.livePid != nil else { return false }
        guard let updatedAt = snap.updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > 2 * 3600
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

extension SourceSnapshot {
    /// Fill work status, task counts, and per-file line totals once per refresh.
    static func withDerivedFields(_ snap: SourceSnapshot) -> SourceSnapshot {
        var s = snap
        s.tasksDone = s.tasks.filter { $0.status == "completed" }.count
        s.tasksInProgress = s.tasks.filter { $0.status == "in_progress" }.count
        s.tasksPending = s.tasks.filter { $0.status == "pending" }.count
        s.workState = WorkStatusResolver.resolveStable(s)
        s.fileChanges = s.fileChanges.map { group in
            var g = group
            g.linesAdded = g.edits.reduce(0) { $0 + $1.rawLinesAdded }
            g.linesRemoved = g.edits.reduce(0) { $0 + $1.rawLinesRemoved }
            return g
        }
        return s
    }
}

/// Per-project counts for the trust board sidebar rollup.
struct FolderTrustSummary: Equatable {
    let counts: [WorkStatus: Int]
    let worstRank: Int
    let attentionCount: Int

    /// Compact line, e.g. `1 Needs you · 2 Risky · 1 Ready`.
    var rollupLine: String? {
        let order: [WorkStatus] = [.needsYou, .testsFailed, .stuck, .risky, .ready, .working]
        let parts = order.compactMap { status -> String? in
            let count = counts[status] ?? 0
            guard count > 0 else { return nil }
            let label = status.rawValue
            return count == 1 ? "1 \(label)" : "\(count) \(label)"
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}

extension SessionFolder {
    func trustSummary(workStates: [String: WorkState]) -> FolderTrustSummary {
        var counts: [WorkStatus: Int] = [:]
        var worst = 99
        var attention = 0
        for snap in snapshots {
            let work = workStates[snap.id] ?? snap.workState
            counts[work.status, default: 0] += 1
            worst = min(worst, work.rank)
            if work.status != .done { attention += 1 }
        }
        if snapshots.isEmpty { worst = 99 }
        return FolderTrustSummary(counts: counts, worstRank: worst, attentionCount: attention)
    }

    func visibleSnapshots(showInactive: Bool, workStates: [String: WorkState]) -> [SourceSnapshot] {
        guard !showInactive else { return snapshots }
        return snapshots.filter { snap in
            let work = workStates[snap.id] ?? snap.workState
            return !WorkStatusResolver.isInactiveInbox(work)
        }
    }

    static func makeStats(from snapshots: [SourceSnapshot]) -> FolderStats {
        var seenFiles: Set<String> = []
        for path in snapshots.flatMap(\.filesEdited) {
            seenFiles.insert(path)
        }
        let tasks = snapshots.flatMap(\.tasks)
        let tools = Dictionary(grouping: snapshots, by: \.tool)
            .map { "\($0.key) \($0.value.count)" }
            .sorted()
            .joined(separator: " · ")
        return FolderStats(
            running: snapshots.filter { $0.state == .running }.count,
            awaiting: snapshots.filter { $0.state == .awaiting }.count,
            tasksDone: tasks.filter { $0.status == "completed" }.count,
            taskCount: tasks.count,
            uniqueFileCount: seenFiles.count,
            toolsSummary: tools
        )
    }
}
