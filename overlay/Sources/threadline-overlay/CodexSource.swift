import Foundation

enum CodexSource {
    struct ParsedSession {
        var model: String?
        var contextLimit: Int?
        var lastAssistant: String?
        var lastUser: String?
        var lastTokenUsage: (input: Int, cached: Int, output: Int)?
        var sawTaskLifecycle = false
        var sawStartedAfterComplete = false
        var userTurns = 0
        var assistantTurns = 0
        var filesEditedOrder: [String] = []
        var toolCounts: [String: Int] = [:]
        var toolTokens: [String: Int] = [:]
        var linesAdded = 0
        var linesRemoved = 0
        var fileChanges: [FileChangeGroup] = []
    }

    private struct CacheEntry {
        let mtime: Date
        let parsed: ParsedSession
    }

    private static var sessionCache: [String: CacheEntry] = [:]
    private static let sessionCacheLock = NSLock()

    /// One snapshot per unique `session_meta.cwd` whose newest rollout file is
    /// more recent than `since`.
    static func readAll(since cutoff: Date) -> [SourceSnapshot] {
        let fm = FileManager.default
        let root = (fm.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".codex/sessions")
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                             includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles])
        else { return [] }
        var all: [(URL, Date)] = []
        for case let u as URL in enumerator {
            guard u.pathExtension == "jsonl" else { continue }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true, let m = v?.contentModificationDate, m >= cutoff else { continue }
            all.append((u, m))
        }
        all.sort { $0.1 > $1.1 }

        var bestPerCwd: [String: (URL, Date)] = [:]
        for (url, mtime) in all {
            guard let cwd = readSessionCwd(at: url) else { continue }
            if let existing = bestPerCwd[cwd], existing.1 >= mtime { continue }
            bestPerCwd[cwd] = (url, mtime)
        }

        var out: [SourceSnapshot] = []
        for (cwd, (url, mtime)) in bestPerCwd {
            if let snap = snapshot(at: url, mtime: mtime, knownCwd: cwd) {
                out.append(snap)
            }
        }
        return out
    }

    private static func readSessionCwd(at url: URL) -> String? {
        guard let head = headOfFile(path: url.path, maxBytes: 64 * 1024) else { return nil }
        for raw in head.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  rec["type"] as? String == "session_meta",
                  let payload = rec["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String
            else { continue }
            return cwd
        }
        return nil
    }

    static func snapshot(forJSONL path: String) -> SourceSnapshot? {
        let url = URL(fileURLWithPath: path)
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              let cwd = readSessionCwd(at: url)
        else { return nil }
        return snapshot(at: url, mtime: mtime, knownCwd: cwd)
    }

    private static func snapshot(at url: URL, mtime: Date, knownCwd: String) -> SourceSnapshot? {
        var snap = SourceSnapshot(id: "codex:\(url.path)",
                                  tool: "Codex",
                                  badge: "CDX")
        snap.updatedAt = mtime
        snap.cwd = knownCwd
        snap.jsonlPath = url.path

        let parsed = parseSession(at: url, mtime: mtime)
        snap.model = parsed.model
        snap.lastText = parsed.lastAssistant ?? parsed.lastUser

        let ageSec = -mtime.timeIntervalSinceNow
        if parsed.sawTaskLifecycle {
            if parsed.sawStartedAfterComplete { snap.state = .running }
            else if ageSec > 300              { snap.state = .stale }
            else                              { snap.state = .idle }
        } else if ageSec < 5                  { snap.state = .running }
        else if ageSec > 300                  { snap.state = .stale }
        else                                  { snap.state = .idle }

        if let u = parsed.lastTokenUsage, let limit = parsed.contextLimit, limit > 0 {
            snap.contextPercent = min(1.0, Double(u.input + u.cached) / Double(limit))
        }
        if let info = Git.info(cwd: knownCwd) {
            snap.branch = info.branch
            snap.dirtyCount = info.dirty
        }
        snap.userTurns = parsed.userTurns
        snap.assistantTurns = parsed.assistantTurns
        snap.filesEdited = parsed.filesEditedOrder
        snap.toolCallCounts = parsed.toolCounts
        snap.toolTokenEstimate = parsed.toolTokens
        snap.linesAdded = parsed.linesAdded
        snap.linesRemoved = parsed.linesRemoved
        snap.fileChanges = parsed.fileChanges
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let birth = attrs[.creationDate] as? Date {
            snap.sessionStart = birth
        }
        return SourceSnapshot.withDerivedFields(snap)
    }

    private static func parseSession(at url: URL, mtime: Date) -> ParsedSession {
        sessionCacheLock.lock()
        if let hit = sessionCache[url.path], hit.mtime == mtime {
            sessionCacheLock.unlock()
            return hit.parsed
        }
        sessionCacheLock.unlock()

        let parsed = scanFile(at: url)
        sessionCacheLock.lock()
        sessionCache[url.path] = CacheEntry(mtime: mtime, parsed: parsed)
        if sessionCache.count > 32 {
            let drop = sessionCache.keys.sorted().prefix(sessionCache.count - 24)
            drop.forEach { sessionCache.removeValue(forKey: $0) }
        }
        sessionCacheLock.unlock()
        return parsed
    }

    private static func scanFile(at url: URL) -> ParsedSession {
        var out = ParsedSession()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return out }

        var editSeq = 0
        var pendingPatchInputs: [String: String] = [:]
        var editsByFile: [String: [FileEditOp]] = [:]
        var filesEditedSeen: Set<String> = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = rec["type"] as? String ?? ""
            let payload = rec["payload"] as? [String: Any] ?? [:]
            switch type {
            case "session_meta":
                if let m = payload["model"] as? String { out.model = m }
                if let limit = payload["model_context_window"] as? Int { out.contextLimit = limit }
            case "event_msg":
                let etype = payload["type"] as? String
                if etype == "task_started" {
                    out.sawTaskLifecycle = true
                    out.sawStartedAfterComplete = true
                }
                if etype == "task_complete" {
                    out.sawTaskLifecycle = true
                    out.sawStartedAfterComplete = false
                }
                if etype == "agent_message", let m = payload["message"] as? String, !m.isEmpty {
                    out.lastAssistant = m
                }
                if etype == "user_message",  let m = payload["message"] as? String, !m.isEmpty {
                    out.lastUser = m
                }
                if etype == "token_count", let info = payload["info"] as? [String: Any] {
                    let i = (info["input_tokens"]         as? Int) ?? 0
                    let c = (info["cached_input_tokens"]  as? Int) ?? 0
                    let o = (info["output_tokens"]        as? Int) ?? 0
                    if i + c + o > 0 { out.lastTokenUsage = (i, c, o) }
                }
            case "response_item":
                let ptype = payload["type"] as? String
                if ptype == "message" {
                    let role = payload["role"] as? String
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let lineText = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                    if !lineText.isEmpty {
                        if role == "assistant" { out.lastAssistant = lineText; out.assistantTurns += 1 }
                        else if role == "user" { out.lastUser = lineText; out.userTurns += 1 }
                    }
                } else if ptype == "custom_tool_call" {
                    let name = payload["name"] as? String ?? ""
                    guard !name.isEmpty else { break }
                    out.toolCounts[name, default: 0] += 1
                    if let rawInput = payload["input"] as? String {
                        out.toolTokens[name, default: 0] += estimateTokens(rawInput)
                        if name == "apply_patch", let callID = payload["call_id"] as? String {
                            pendingPatchInputs[callID] = rawInput
                        }
                    }
                }
            default: break
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  rec["type"] as? String == "event_msg",
                  let payload = rec["payload"] as? [String: Any],
                  payload["type"] as? String == "patch_apply_end",
                  let callID = payload["call_id"] as? String
            else { continue }

            let changes = payload["changes"] as? [String: Any] ?? [:]
            let fallbackPatch = pendingPatchInputs[callID] ?? ""
            for (path, rawChange) in changes.sorted(by: { $0.key < $1.key }) {
                let change = rawChange as? [String: Any] ?? [:]
                let patch = (change["unified_diff"] as? String) ?? patchForPath(path, in: fallbackPatch)
                let counts = countPatchLines(patch)
                editSeq += 1
                let truncated = truncate(patch)
                let op = FileEditOp.withDisplays(seq: editSeq,
                                               tool: "apply_patch",
                                               timestamp: rec["timestamp"] as? String ?? "",
                                               patchText: truncated,
                                               note: change["type"] as? String ?? "",
                                               rawLinesAdded: counts.added,
                                               rawLinesRemoved: counts.removed)
                editsByFile[path, default: []].append(op)
                if !filesEditedSeen.contains(path) {
                    filesEditedSeen.insert(path)
                    out.filesEditedOrder.append(path)
                }
                out.linesAdded += counts.added
                out.linesRemoved += counts.removed
            }
        }

        out.fileChanges = out.filesEditedOrder.map { path in
            FileChangeGroup(path: path, edits: editsByFile[path] ?? [])
        }
        return out
    }

    private static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    private static func countPatchLines(_ patch: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    private static func truncate(_ s: String, max: Int = 4096) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "\n… (\(s.count - max) chars truncated)"
    }

    private static func patchForPath(_ path: String, in patch: String) -> String {
        guard !patch.isEmpty else { return "" }
        var out: [String] = []
        var capturing = false
        let markers = [
            "*** Update File: \(path)",
            "*** Add File: \(path)",
            "*** Delete File: \(path)",
            "*** Update File: \((path as NSString).lastPathComponent)",
        ]
        for line in patch.components(separatedBy: "\n") {
            if markers.contains(line) {
                capturing = true
                continue
            }
            if line.hasPrefix("*** ") && capturing { break }
            if capturing { out.append(line) }
        }
        return out.joined(separator: "\n")
    }
}
