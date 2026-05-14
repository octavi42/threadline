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
        var lastRecordRole: String?
        var totals = TokenTotals()
        var toolCounts: [String: Int] = [:]
        var filesEditedOrder: [String] = []
        var filesEditedSeen: Set<String> = []
        var userTurns = 0
        var assistantTurns = 0
        var earliestTs: Date?

        // Task tracking: Claude Code's task tools emit TaskCreate / TaskUpdate
        // separately. The task ID is assigned by the system and surfaces in
        // the tool_result body ("Task #N created successfully: ..."), so we
        // correlate TaskCreate → tool_result via tool_use_id.
        // TodoWrite (legacy) writes the entire list in one input dict.
        struct WIPTask { var content: String; var status: String }
        var taskByID: [String: WIPTask] = [:]
        var creationOrder: [String] = []
        var pendingByToolUseID: [String: String] = [:]   // toolUseID -> subject
        var todoWriteFallback: [[String: Any]] = []

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
                            let input = block["input"] as? [String: Any] ?? [:]
                            let toolUseID = block["id"] as? String

                            switch name {
                            case "TodoWrite":
                                if let todos = input["todos"] as? [[String: Any]] {
                                    todoWriteFallback = todos
                                }
                            case "TaskCreate":
                                if let useID = toolUseID,
                                   let subject = input["subject"] as? String {
                                    pendingByToolUseID[useID] = subject
                                }
                            case "TaskUpdate":
                                if let taskID = input["taskId"] as? String,
                                   var wip = taskByID[taskID] {
                                    if let newStatus = input["status"] as? String {
                                        wip.status = newStatus
                                    }
                                    if let newSubject = input["subject"] as? String {
                                        wip.content = newSubject
                                    }
                                    taskByID[taskID] = wip
                                }
                            default:
                                break
                            }
                            if let path = input["file_path"] as? String,
                               !filesEditedSeen.contains(path) {
                                filesEditedSeen.insert(path)
                                filesEditedOrder.append(path)
                            }
                        }
                    case "tool_result":
                        // Pair TaskCreate tool_use with its tool_result so we
                        // can recover the system-assigned task ID.
                        if let useID = block["tool_use_id"] as? String,
                           let subject = pendingByToolUseID[useID] {
                            pendingByToolUseID.removeValue(forKey: useID)
                            let bodyText = extractToolResultText(block["content"]) ?? ""
                            if let id = parseTaskID(from: bodyText) {
                                taskByID[id] = WIPTask(content: subject, status: "pending")
                                creationOrder.append(id)
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

        // Whole-file aggregates (tasks + per-tool token attribution).
        // Cached by mtime so we only pay the full scan once per change.
        let aggregates = scanFullSession(jsonlPath: jsonlPath, mtime: mtime)
        snap.toolTokenEstimate = aggregates.toolTokens
        let finalTasks = aggregates.tasks
            .ifEmpty(else: {
                // Fall back to whatever we found in the tail.
                var t: [TaskItem] = []
                if !creationOrder.isEmpty {
                    for id in creationOrder {
                        if let wip = taskByID[id], wip.status != "deleted" {
                            t.append(TaskItem(content: wip.content, status: wip.status))
                        }
                    }
                } else if !todoWriteFallback.isEmpty {
                    t = todoWriteFallback.compactMap { dict in
                        guard let c = dict["content"] as? String,
                              let s = dict["status"] as? String else { return nil }
                        return TaskItem(content: c, status: s)
                    }
                }
                return t
            })
        if let active = finalTasks.first(where: { $0.status == "in_progress" }) {
            snap.currentTask = active.content
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
        snap.tasks = finalTasks
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

    // MARK: - full-file scan (with mtime cache)

    struct FullSessionAggregates {
        let tasks: [TaskItem]
        /// Estimated tokens per tool, summed across input + result bytes.
        let toolTokens: [String: Int]
    }
    private struct FullSessionCacheEntry {
        let mtime: Date
        let aggregates: FullSessionAggregates
    }
    private static var sessionCache: [String: FullSessionCacheEntry] = [:]
    private static let sessionCacheLock = NSLock()

    /// One full sweep through the JSONL that produces every whole-file
    /// aggregation the snapshot needs. Cached by (path, mtime) so
    /// consecutive refreshes against an unchanged file are free.
    ///
    /// Why one combined pass: the previous design had `scanAllTasks` widen
    /// its fast-filter and walk the file once per metric. Adding per-tool
    /// token attribution would have needed a second full scan. Folding both
    /// into one pass keeps a single mtime cache and one file read.
    private static func scanFullSession(jsonlPath: String, mtime: Date) -> FullSessionAggregates {
        sessionCacheLock.lock()
        if let hit = sessionCache[jsonlPath], hit.mtime == mtime {
            sessionCacheLock.unlock()
            return hit.aggregates
        }
        sessionCacheLock.unlock()

        let empty = FullSessionAggregates(tasks: [], toolTokens: [:])
        guard let text = try? String(contentsOfFile: jsonlPath, encoding: .utf8) else {
            return empty
        }

        struct WIP { var content: String; var status: String }
        var byID: [String: WIP] = [:]
        var order: [String] = []
        var pending: [String: String] = [:]
        var todoWriteFallback: [[String: Any]] = []
        var toolByUseID: [String: String] = [:]
        var inputBytes: [String: Int] = [:]
        var resultBytes: [String: Int] = [:]

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(raw)
            // Fast filter — accept any line that might contribute. tool_use
            // lines feed token attribution; tool_result and the three task
            // tools feed task reconstruction.
            let interesting = s.contains("\"tool_use\"")
                           || s.contains("\"tool_result\"")
            guard interesting else { continue }
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]]
            else { continue }

            for block in content {
                let type = block["type"] as? String
                if type == "tool_use" {
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let useID = block["id"] as? String

                    // Token attribution: count bytes of the encoded input.
                    if let useID = useID { toolByUseID[useID] = name }
                    if let bytes = try? JSONSerialization.data(withJSONObject: input, options: []) {
                        inputBytes[name, default: 0] += bytes.count
                    }

                    // Task tracking.
                    switch name {
                    case "TodoWrite":
                        if let todos = input["todos"] as? [[String: Any]] {
                            todoWriteFallback = todos
                        }
                    case "TaskCreate":
                        if let useID = useID, let subject = input["subject"] as? String {
                            pending[useID] = subject
                        }
                    case "TaskUpdate":
                        if let taskID = input["taskId"] as? String, var wip = byID[taskID] {
                            if let s = input["status"] as? String  { wip.status = s }
                            if let s = input["subject"] as? String { wip.content = s }
                            byID[taskID] = wip
                        }
                    default: break
                    }
                } else if type == "tool_result",
                          let useID = block["tool_use_id"] as? String {
                    let body = extractToolResultText(block["content"]) ?? ""

                    // Token attribution: charge the result bytes to whichever
                    // tool emitted them.
                    if let toolName = toolByUseID[useID] {
                        resultBytes[toolName, default: 0] += body.utf8.count
                    }

                    // Task reconstruction.
                    if let subject = pending[useID] {
                        pending.removeValue(forKey: useID)
                        if let id = parseTaskID(from: body) {
                            byID[id] = WIP(content: subject, status: "pending")
                            order.append(id)
                        }
                    }
                }
            }
        }

        var tasks: [TaskItem] = []
        if !order.isEmpty {
            for id in order {
                if let wip = byID[id], wip.status != "deleted" {
                    tasks.append(TaskItem(content: wip.content, status: wip.status))
                }
            }
        } else {
            tasks = todoWriteFallback.compactMap { dict in
                guard let c = dict["content"] as? String,
                      let s = dict["status"] as? String else { return nil }
                return TaskItem(content: c, status: s)
            }
        }

        // ~4 bytes per token is the common heuristic for mixed English/code.
        var toolTokens: [String: Int] = [:]
        for name in Set(inputBytes.keys).union(resultBytes.keys) {
            let bytes = (inputBytes[name] ?? 0) + (resultBytes[name] ?? 0)
            if bytes > 0 { toolTokens[name] = bytes / 4 }
        }

        let aggregates = FullSessionAggregates(tasks: tasks, toolTokens: toolTokens)
        sessionCacheLock.lock()
        sessionCache[jsonlPath] = FullSessionCacheEntry(mtime: mtime, aggregates: aggregates)
        sessionCacheLock.unlock()
        return aggregates
    }

    /// Pull the assigned task ID out of "Task #N created successfully: ..."
    private static func parseTaskID(from body: String) -> String? {
        guard let hashRange = body.range(of: "Task #") else { return nil }
        var idx = hashRange.upperBound
        var digits = ""
        while idx < body.endIndex, body[idx].isNumber {
            digits.append(body[idx])
            idx = body.index(after: idx)
        }
        return digits.isEmpty ? nil : digits
    }

    /// Tool results carry their body either as a plain String or as an array
    /// of `{type: "text", text: "..."}` blocks.
    private static func extractToolResultText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return nil }
        let parts = arr.compactMap { $0["text"] as? String }
        return parts.joined(separator: " ")
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

extension Array {
    /// Returns self when non-empty, otherwise the value produced by `else`.
    fileprivate func ifEmpty(else fallback: () -> [Element]) -> [Element] {
        isEmpty ? fallback() : self
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
