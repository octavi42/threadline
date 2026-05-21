import Foundation

/// Cursor Agent CLI sessions under `~/.cursor/projects/*/agent-transcripts/*/*.jsonl`.
enum CursorAgentSource {
    private static var projectsRoot: String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".cursor/projects")
    }

    /// `sessionUUID` → absolute JSONL path (built during scans).
    private static var sessionPathIndex: [String: String] = [:]
    private static let indexLock = NSLock()

    /// All JSONL sessions modified after `cutoff`.
    static func readAll(since cutoff: Date) -> [SourceSnapshot] {
        rebuildSessionIndex()
        var out: [SourceSnapshot] = []
        for (_, path) in sessionPathIndex.sorted(by: { $0.key < $1.key }) {
            guard let mtime = modificationDate(path: path), mtime >= cutoff else { continue }
            if let snap = snapshot(jsonlPath: path, mtime: mtime) {
                out.append(snap)
            }
        }
        return out
    }

    static func snapshot(forJSONL path: String) -> SourceSnapshot? {
        guard let mtime = modificationDate(path: path) else { return nil }
        return snapshot(jsonlPath: path, mtime: mtime)
    }

    /// Resolve a live chat `store.db` session id to its transcript JSONL, if exported.
    static func jsonlPath(forSessionID sessionID: String) -> String? {
        rebuildSessionIndex()
        indexLock.lock()
        let path = sessionPathIndex[sessionID]
        indexLock.unlock()
        return path
    }

    /// Map workspace cwd → project slug directory under `~/.cursor/projects`.
    static func projectDir(forWorkspace cwd: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: projectsRoot) else { return nil }
        for entry in entries {
            let trusted = (projectsRoot as NSString)
                .appendingPathComponent(entry)
                .appending("/.workspace-trusted")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: trusted)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = obj["workspacePath"] as? String,
                  path == cwd
            else { continue }
            return (projectsRoot as NSString).appendingPathComponent(entry)
        }
        return nil
    }

    // MARK: - snapshot

    private static func snapshot(jsonlPath: String, mtime: Date) -> SourceSnapshot? {
        guard let tail = tailOfFile(path: jsonlPath, maxBytes: 128 * 1024) else { return nil }
        guard let cwd = workspacePath(forJSONL: jsonlPath) ?? inferCwd(fromTail: tail) else {
            return nil
        }

        var snap = SourceSnapshot(id: "cursor:\(jsonlPath)",
                                  tool: "Cursor",
                                  badge: "CUR")
        snap.cwd = cwd
        snap.updatedAt = mtime
        snap.jsonlPath = jsonlPath

        var lastAssistantText: String?
        var lastUserText: String?
        var lastToolName: String?
        var lastToolInput: [String: Any]?
        var lastRecordRole: String?
        var filesEditedOrder: [String] = []
        var filesEditedSeen: Set<String> = []
        var toolCounts: [String: Int] = [:]
        var userTurns = 0
        var assistantTurns = 0

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = obj["role"] as? String,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            lastRecordRole = role
            if role == "user" { userTurns += 1 }
            if role == "assistant" { assistantTurns += 1 }

            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let t = block["text"] as? String, !t.isEmpty else { continue }
                    let cleaned = stripCursorMarkup(t)
                    guard !cleaned.isEmpty, !cleaned.hasPrefix("[REDACTED]") else { continue }
                    if role == "assistant" {
                        lastAssistantText = cleaned
                    } else if role == "user" {
                        lastUserText = cleaned
                    }
                case "tool_use":
                    guard let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    lastToolName = name
                    lastToolInput = input
                    toolCounts[name, default: 0] += 1
                    if let path = filePath(from: input), !filesEditedSeen.contains(path) {
                        filesEditedSeen.insert(path)
                        filesEditedOrder.append(path)
                    }
                default:
                    break
                }
            }
        }

        let ageSec = -mtime.timeIntervalSinceNow
        if ageSec < 3 { snap.state = .running }
        else if lastRecordRole == "user" { snap.state = .awaiting }
        else if ageSec > 300 { snap.state = .stale }
        else { snap.state = .idle }

        if let name = lastToolName {
            snap.lastTool = describe(tool: name, input: lastToolInput)
        }
        snap.lastText = lastAssistantText ?? lastUserText
        snap.userTurns = userTurns
        snap.assistantTurns = assistantTurns
        snap.filesEdited = filesEditedOrder
        snap.toolCallCounts = toolCounts

        let aggregates = scanFullSession(jsonlPath: jsonlPath, mtime: mtime)
        snap.linesAdded = aggregates.linesAdded
        snap.linesRemoved = aggregates.linesRemoved
        snap.fileChanges = aggregates.fileChanges
        if snap.filesEdited.isEmpty {
            snap.filesEdited = aggregates.filesEditedOrder
        }

        if let info = Git.info(cwd: cwd) {
            snap.branch = info.branch
            snap.dirtyCount = info.dirty
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
           let birth = attrs[.creationDate] as? Date {
            snap.sessionStart = birth
        }

        return SourceSnapshot.withDerivedFields(snap)
    }

    // MARK: - full-file aggregates

    private struct FullSessionAggregates {
        let linesAdded: Int
        let linesRemoved: Int
        let fileChanges: [FileChangeGroup]
        let filesEditedOrder: [String]
    }

    private struct FullSessionCacheEntry {
        let mtime: Date
        let aggregates: FullSessionAggregates
    }

    private static var sessionCache: [String: FullSessionCacheEntry] = [:]
    private static let sessionCacheLock = NSLock()

    private static func scanFullSession(jsonlPath: String, mtime: Date) -> FullSessionAggregates {
        sessionCacheLock.lock()
        if let hit = sessionCache[jsonlPath], hit.mtime == mtime {
            sessionCacheLock.unlock()
            return hit.aggregates
        }
        sessionCacheLock.unlock()

        let empty = FullSessionAggregates(linesAdded: 0, linesRemoved: 0,
                                        fileChanges: [], filesEditedOrder: [])
        guard let text = try? String(contentsOfFile: jsonlPath, encoding: .utf8) else {
            return empty
        }

        var editSeq = 0
        var linesAdded = 0
        var linesRemoved = 0
        var editsByFile: [String: [FileEditOp]] = [:]
        var filesEditedSeen: Set<String> = []
        var filesEditedOrder: [String] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            for block in content where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any],
                      let path = filePath(from: input)
                else { continue }

                let ts = obj["timestamp"] as? String ?? ""

                switch name {
                case "StrReplace", "Edit", "MultiEdit":
                    let old = input["old_string"] as? String ?? ""
                    let new = input["new_string"] as? String ?? ""
                    let added = lineCount(new)
                    let removed = lineCount(old)
                    linesAdded += added
                    linesRemoved += removed
                    editSeq += 1
                    editsByFile[path, default: []].append(
                        FileEditOp.withDisplays(seq: editSeq, tool: "Edit", timestamp: ts,
                                                oldText: old, newText: new,
                                                rawLinesAdded: added, rawLinesRemoved: removed)
                    )
                case "Write":
                    let body = input["contents"] as? String ?? input["content"] as? String ?? ""
                    let added = lineCount(body)
                    linesAdded += added
                    editSeq += 1
                    editsByFile[path, default: []].append(
                        FileEditOp.withDisplays(seq: editSeq, tool: "Write", timestamp: ts,
                                                newText: body, note: "full file write",
                                                rawLinesAdded: added)
                    )
                default:
                    continue
                }

                if !filesEditedSeen.contains(path) {
                    filesEditedSeen.insert(path)
                    filesEditedOrder.append(path)
                }
            }
        }

        let fileChanges = filesEditedOrder.map { path in
            let edits = editsByFile[path] ?? []
            var group = FileChangeGroup(path: path, edits: edits)
            group.linesAdded = edits.reduce(0) { $0 + $1.rawLinesAdded }
            group.linesRemoved = edits.reduce(0) { $0 + $1.rawLinesRemoved }
            return group
        }

        let aggregates = FullSessionAggregates(linesAdded: linesAdded,
                                               linesRemoved: linesRemoved,
                                               fileChanges: fileChanges,
                                               filesEditedOrder: filesEditedOrder)
        sessionCacheLock.lock()
        sessionCache[jsonlPath] = FullSessionCacheEntry(mtime: mtime, aggregates: aggregates)
        sessionCacheLock.unlock()
        return aggregates
    }

    // MARK: - index + workspace

    /// Refresh the session-id → JSONL map before live PID matching.
    static func refreshSessionIndex() {
        rebuildSessionIndex()
    }

    private static func rebuildSessionIndex() {
        var index: [String: String] = [:]
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsRoot) else {
            storeIndex(index)
            return
        }

        for project in projects {
            let transcripts = (projectsRoot as NSString)
                .appendingPathComponent(project)
                .appending("/agent-transcripts")
            guard let sessions = try? fm.contentsOfDirectory(atPath: transcripts) else { continue }
            for sessionID in sessions {
                let jsonl = (transcripts as NSString)
                    .appendingPathComponent(sessionID)
                    .appending("/\(sessionID).jsonl")
                if fm.fileExists(atPath: jsonl) {
                    index[sessionID] = jsonl
                }
            }
        }
        storeIndex(index)
    }

    private static func storeIndex(_ index: [String: String]) {
        indexLock.lock()
        sessionPathIndex = index
        indexLock.unlock()
    }

    private static func workspacePath(forJSONL jsonlPath: String) -> String? {
        guard jsonlPath.contains("/.cursor/projects/") else { return nil }
        let parts = jsonlPath.split(separator: "/")
        guard let idx = parts.firstIndex(of: "projects"), idx + 1 < parts.count else {
            return nil
        }
        let projectSlug = String(parts[idx + 1])
        let trusted = (projectsRoot as NSString)
            .appendingPathComponent(projectSlug)
            .appending("/.workspace-trusted")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: trusted)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["workspacePath"] as? String
        else { return nil }
        return path
    }

    // MARK: - helpers

    private static func modificationDate(path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func filePath(from input: [String: Any]) -> String? {
        (input["path"] as? String) ?? (input["file_path"] as? String)
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// When JSONL lives outside `~/.cursor/projects` (e.g. test fixtures), infer
    /// cwd from the first absolute file path in tool inputs.
    private static func inferCwd(fromTail tail: String) -> String? {
        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content where block["type"] as? String == "tool_use" {
                guard let input = block["input"] as? [String: Any],
                      let path = filePath(from: input),
                      path.hasPrefix("/")
                else { continue }
                return (path as NSString).deletingLastPathComponent
            }
        }
        return nil
    }

    private static func stripCursorMarkup(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "<user_query>") {
            s = String(s[range.upperBound...])
        }
        if let range = s.range(of: "</user_query>") {
            s = String(s[..<range.lowerBound])
        }
        if let range = s.range(of: "<timestamp>") {
            if let end = s.range(of: "</timestamp>") {
                s.removeSubrange(range.lowerBound..<end.upperBound)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describe(tool: String, input: [String: Any]?) -> String {
        guard let input = input else { return tool }
        let target: String
        if let p = filePath(from: input) {
            target = (p as NSString).lastPathComponent
        } else if let c = input["command"] as? String {
            target = c.split(separator: "\n").first.map(String.init) ?? c
        } else if let q = input["pattern"] as? String {
            target = q
        } else if let q = input["query"] as? String {
            target = q
        } else {
            target = ""
        }
        return target.isEmpty ? tool : "\(tool) \(target)"
    }
}
