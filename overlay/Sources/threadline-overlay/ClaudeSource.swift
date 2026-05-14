import Foundation

enum ClaudeSource {
    /// One snapshot per Claude project (`~/.claude/projects/<encoded-cwd>/`)
    /// whose newest `.jsonl` is more recent than `since`.
    static func readAll(since cutoff: Date) -> [SourceSnapshot] {
        let fm = FileManager.default
        let root = (fm.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".claude/projects")
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var out: [SourceSnapshot] = []
        for proj in projects {
            let projDir = (root as NSString).appendingPathComponent(proj)
            guard let files = try? fm.contentsOfDirectory(atPath: projDir) else { continue }
            var newest: (path: String, mtime: Date)?
            for f in files where f.hasSuffix(".jsonl") {
                let path = (projDir as NSString).appendingPathComponent(f)
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let m = attrs[.modificationDate] as? Date {
                    if newest == nil || m > newest!.mtime { newest = (path, m) }
                }
            }
            guard let pick = newest, pick.mtime >= cutoff else { continue }
            if let snap = snapshot(jsonlPath: pick.path, mtime: pick.mtime, projectDir: proj) {
                out.append(snap)
            }
        }
        return out
    }

    /// Build a snapshot for a specific JSONL file. Used by LiveAgents to
    /// produce one row per *live tab*, since multiple tabs in the same
    /// project directory each have their own JSONL.
    static func snapshot(forJSONL path: String) -> SourceSnapshot? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let projectDir = (path as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? ""
        return snapshot(jsonlPath: path, mtime: mtime, projectDir: projectDir)
    }

    private static func snapshot(jsonlPath: String,
                                 mtime: Date,
                                 projectDir: String) -> SourceSnapshot? {
        // ID is the absolute JSONL path so each tab is uniquely addressable
        // even when multiple tabs share the same project directory.
        var snap = SourceSnapshot(id: "claude:\(jsonlPath)",
                                  tool: "Claude",
                                  badge: "CLD")
        _ = projectDir   // kept in case future code wants it
        snap.updatedAt = mtime

        guard let tail = tailOfFile(path: jsonlPath, maxBytes: 128 * 1024) else {
            return snap
        }

        var cwd: String?
        var model: String?
        var lastAssistantText: String?
        var lastUserText: String?
        var lastToolUseName: String?
        var lastToolUseInput: [String: Any]?
        var lastTodos: [[String: Any]] = []
        var lastRecordRole: String?
        var totals = TokenTotals()
        var toolCounts: [String: Int] = [:]
        var filesEditedOrder: [String] = []
        var filesEditedSeen: Set<String> = []
        var userTurns = 0
        var assistantTurns = 0
        var earliestTs: Date?

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = obj["type"] as? String ?? ""
            if let c = obj["cwd"] as? String { cwd = c }
            let msg = obj["message"] as? [String: Any] ?? [:]
            if let m = msg["model"] as? String { model = m }

            if type == "assistant" || type == "user" { lastRecordRole = type }
            if type == "user"      { userTurns += 1 }
            if type == "assistant" { assistantTurns += 1 }

            // Track the earliest timestamp we see in the tail as a rough
            // proxy for session start. (For a more accurate start time the
            // ClaudeSource caller should use the JSONL's birth time.)
            if let tsStr = obj["timestamp"] as? String,
               let ts = parseISO8601(tsStr),
               earliestTs == nil || ts < earliestTs! {
                earliestTs = ts
            }

            if let usage = msg["usage"] as? [String: Any] { totals.add(usage) }

            if let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty {
                            if msg["role"] as? String == "assistant" {
                                lastAssistantText = t
                            } else if msg["role"] as? String == "user", !t.hasPrefix("<") {
                                lastUserText = t
                            }
                        }
                    case "tool_use":
                        if let name = block["name"] as? String {
                            lastToolUseName = name
                            lastToolUseInput = block["input"] as? [String: Any]
                            toolCounts[name, default: 0] += 1
                            if name == "TodoWrite",
                               let input = block["input"] as? [String: Any],
                               let todos = input["todos"] as? [[String: Any]] {
                                lastTodos = todos
                            }
                            if let input = block["input"] as? [String: Any],
                               let path = input["file_path"] as? String,
                               !filesEditedSeen.contains(path) {
                                filesEditedSeen.insert(path)
                                filesEditedOrder.append(path)
                            }
                        }
                    default: break
                    }
                }
            }
        }

        snap.cwd = cwd
        snap.model = model

        let ageSec = -mtime.timeIntervalSinceNow
        if ageSec < 3                          { snap.state = .running }
        else if lastRecordRole == "user"       { snap.state = .awaiting }
        else if ageSec > 300                   { snap.state = .stale }
        else                                   { snap.state = .idle }

        if let active = lastTodos.first(where: { ($0["status"] as? String) == "in_progress" }),
           let title = active["content"] as? String {
            snap.currentTask = title
        }
        if let name = lastToolUseName {
            snap.lastTool = describe(tool: name, input: lastToolUseInput)
        }
        snap.lastText = lastAssistantText ?? lastUserText

        let inContext = totals.lastInContextTokens()
        if let limit = model.flatMap({ ContextLimits.limit(for: $0) }), limit > 0 {
            snap.contextPercent = min(1.0, Double(inContext) / Double(limit))
        }
        if let m = model {
            snap.costUSD = Pricing.usd(model: m,
                                       input: totals.input,
                                       output: totals.output,
                                       cacheCreate: totals.cacheCreate,
                                       cacheRead: totals.cacheRead)
        }
        if let c = cwd, let info = Git.info(cwd: c) {
            snap.branch = info.branch
            snap.dirtyCount = info.dirty
        }

        // Phase-2 fields.
        snap.tasks = lastTodos.compactMap { dict in
            guard let content = dict["content"] as? String,
                  let status = dict["status"] as? String else { return nil }
            return TaskItem(content: content, status: status)
        }
        snap.filesEdited = filesEditedOrder
        snap.toolCallCounts = toolCounts
        snap.userTurns = userTurns
        snap.assistantTurns = assistantTurns
        // For session start, prefer JSONL birth time (more reliable than
        // the earliest record in a tailed window).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
           let birth = attrs[.creationDate] as? Date {
            snap.sessionStart = birth
        } else {
            snap.sessionStart = earliestTs
        }
        snap.jsonlPath = jsonlPath

        return snap
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static func describe(tool: String, input: [String: Any]?) -> String {
        guard let input = input else { return tool }
        let target: String
        if let p = input["file_path"] as? String {
            target = (p as NSString).lastPathComponent
        } else if let c = input["command"] as? String {
            target = c.split(separator: "\n").first.map(String.init) ?? c
        } else if let q = input["pattern"] as? String {
            target = q
        } else if let q = input["query"] as? String {
            target = q
        } else if tool == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            target = "\(todos.count) item\(todos.count == 1 ? "" : "s")"
        } else {
            target = ""
        }
        return target.isEmpty ? tool : "\(tool) \(target)"
    }
}

private struct TokenTotals {
    var input = 0
    var output = 0
    var cacheCreate = 0
    var cacheRead = 0
    var lastInput = 0
    var lastCacheCreate = 0
    var lastCacheRead = 0

    mutating func add(_ usage: [String: Any]) {
        let i  = (usage["input_tokens"]                as? Int) ?? 0
        let o  = (usage["output_tokens"]               as? Int) ?? 0
        let cc = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cr = (usage["cache_read_input_tokens"]     as? Int) ?? 0
        input += i; output += o; cacheCreate += cc; cacheRead += cr
        lastInput = i; lastCacheCreate = cc; lastCacheRead = cr
    }

    func lastInContextTokens() -> Int {
        lastInput + lastCacheCreate + lastCacheRead
    }
}
