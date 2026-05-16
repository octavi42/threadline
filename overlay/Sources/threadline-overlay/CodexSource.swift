import Foundation

enum CodexSource {
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

        // Group by session_meta.cwd; keep the newest jsonl per cwd.
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
        // session_meta records carry the full system prompt and can exceed
        // 4KB; read a larger head so the first newline (record terminator)
        // is included.
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

    /// Build a snapshot for a specific JSONL — used by LiveAgents to produce
    /// one row per live tab. Reads the head to find session_meta.cwd, then
    /// delegates to the existing snapshot builder.
    static func snapshot(forJSONL path: String) -> SourceSnapshot? {
        let url = URL(fileURLWithPath: path)
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              let cwd = readSessionCwd(at: url)
        else { return nil }
        return snapshot(at: url, mtime: mtime, knownCwd: cwd)
    }

    private static func snapshot(at url: URL, mtime: Date, knownCwd: String) -> SourceSnapshot? {
        // ID is the absolute JSONL path so each tab is uniquely addressable
        // even when multiple tabs share the same project (cwd).
        var snap = SourceSnapshot(id: "codex:\(url.path)",
                                  tool: "Codex",
                                  badge: "CDX")
        snap.updatedAt = mtime
        snap.cwd = knownCwd

        guard let text = try? String(contentsOfFile: url.path, encoding: .utf8) else { return snap }

        var model: String?
        var contextLimit: Int?
        var lastAssistant: String?
        var lastUser: String?
        var lastTokenUsage: (input: Int, cached: Int, output: Int)?
        var sawStartedAfterComplete = false
        var userTurns = 0
        var assistantTurns = 0
        var editSeq = 0
        var pendingPatchInputs: [String: String] = [:]
        var editsByFile: [String: [FileEditOp]] = [:]
        var filesEditedOrder: [String] = []
        var filesEditedSeen: Set<String> = []
        var toolCounts: [String: Int] = [:]
        var toolTokens: [String: Int] = [:]
        var linesAdded = 0
        var linesRemoved = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = rec["type"] as? String ?? ""
            let payload = rec["payload"] as? [String: Any] ?? [:]
            switch type {
            case "session_meta":
                if let m = payload["model"] as? String { model = m }
                if let limit = payload["model_context_window"] as? Int { contextLimit = limit }
            case "event_msg":
                let etype = payload["type"] as? String
                if etype == "task_started"  { sawStartedAfterComplete = true }
                if etype == "task_complete" { sawStartedAfterComplete = false }
                if etype == "agent_message", let m = payload["message"] as? String, !m.isEmpty {
                    lastAssistant = m
                }
                if etype == "user_message",  let m = payload["message"] as? String, !m.isEmpty {
                    lastUser = m
                }
                if etype == "token_count", let info = payload["info"] as? [String: Any] {
                    let i = (info["input_tokens"]         as? Int) ?? 0
                    let c = (info["cached_input_tokens"]  as? Int) ?? 0
                    let o = (info["output_tokens"]        as? Int) ?? 0
                    if i + c + o > 0 { lastTokenUsage = (i, c, o) }
                }
            case "response_item":
                let ptype = payload["type"] as? String
                if ptype == "message" {
                    let role = payload["role"] as? String
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                    if !text.isEmpty {
                        if role == "assistant" { lastAssistant = text; assistantTurns += 1 }
                        else if role == "user" { lastUser = text; userTurns += 1 }
                    }
                } else if ptype == "custom_tool_call" {
                    let name = payload["name"] as? String ?? ""
                    guard !name.isEmpty else { break }
                    toolCounts[name, default: 0] += 1
                    if let rawInput = payload["input"] as? String {
                        toolTokens[name, default: 0] += estimateTokens(rawInput)
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
                let op = FileEditOp(seq: editSeq,
                                    tool: "apply_patch",
                                    timestamp: rec["timestamp"] as? String ?? "",
                                    patchText: truncate(patch),
                                    note: change["type"] as? String ?? "",
                                    rawLinesAdded: counts.added,
                                    rawLinesRemoved: counts.removed)
                editsByFile[path, default: []].append(op)
                if !filesEditedSeen.contains(path) {
                    filesEditedSeen.insert(path)
                    filesEditedOrder.append(path)
                }
                linesAdded += counts.added
                linesRemoved += counts.removed
            }
        }

        snap.model = model
        snap.lastText = lastAssistant ?? lastUser

        let ageSec = -mtime.timeIntervalSinceNow
        if sawStartedAfterComplete && ageSec < 30 { snap.state = .running }
        else if ageSec < 5                          { snap.state = .running }
        else if ageSec > 300                        { snap.state = .stale }
        else                                        { snap.state = .idle }

        if let u = lastTokenUsage, let limit = contextLimit, limit > 0 {
            snap.contextPercent = min(1.0, Double(u.input + u.cached) / Double(limit))
        }
        if let info = Git.info(cwd: knownCwd) {
            snap.branch = info.branch
            snap.dirtyCount = info.dirty
        }
        snap.userTurns = userTurns
        snap.assistantTurns = assistantTurns
        snap.filesEdited = filesEditedOrder
        snap.toolCallCounts = toolCounts
        snap.toolTokenEstimate = toolTokens
        snap.linesAdded = linesAdded
        snap.linesRemoved = linesRemoved
        snap.fileChanges = filesEditedOrder.map { path in
            FileChangeGroup(path: path, edits: editsByFile[path] ?? [])
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let birth = attrs[.creationDate] as? Date {
            snap.sessionStart = birth
        }
        snap.jsonlPath = url.path
        return snap
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
