import Foundation

enum ClaudeSource {
    static func read(scopeCwd: String? = nil) -> SourceSnapshot {
        let fm = FileManager.default
        let root = (fm.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".claude/projects")
        var snap = SourceSnapshot(id: "claude", tool: "Claude", badge: "CLD")

        // Fast path: when scope cwd is set, look inside the encoded project
        // dir first. Falls back to global scan if it's empty / missing.
        var newest: (path: String, mtime: Date)?
        if let scope = scopeCwd {
            let encoded = scope.replacingOccurrences(of: "/", with: "-")
            let scopedDir = (root as NSString).appendingPathComponent(encoded)
            if let files = try? fm.contentsOfDirectory(atPath: scopedDir) {
                for f in files where f.hasSuffix(".jsonl") {
                    let path = (scopedDir as NSString).appendingPathComponent(f)
                    if let attrs = try? fm.attributesOfItem(atPath: path),
                       let m = attrs[.modificationDate] as? Date {
                        if newest == nil || m > newest!.mtime { newest = (path, m) }
                    }
                }
            }
        }

        // Global scan if no scope or no scoped match.
        if newest == nil {
            guard let projects = try? fm.contentsOfDirectory(atPath: root) else {
                snap.state = .none; snap.note = "no session"
                return snap
            }
            for proj in projects {
                let projDir = (root as NSString).appendingPathComponent(proj)
                guard let files = try? fm.contentsOfDirectory(atPath: projDir) else { continue }
                for f in files where f.hasSuffix(".jsonl") {
                    let path = (projDir as NSString).appendingPathComponent(f)
                    if let attrs = try? fm.attributesOfItem(atPath: path),
                       let m = attrs[.modificationDate] as? Date {
                        if newest == nil || m > newest!.mtime { newest = (path, m) }
                    }
                }
            }
        }
        guard let pick = newest else {
            snap.state = .none; snap.note = "no session"
            return snap
        }
        snap.updatedAt = pick.mtime

        // Read a chunky tail; sessions average a few KB/turn so 128KB ≈ several turns.
        guard let tail = tailOfFile(path: pick.path, maxBytes: 128 * 1024) else {
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

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = obj["type"] as? String ?? ""
            if let c = obj["cwd"] as? String { cwd = c }
            let msg = obj["message"] as? [String: Any] ?? [:]
            if let m = msg["model"] as? String { model = m }

            if type == "assistant" || type == "user" {
                lastRecordRole = type
            }

            // Accumulate token usage (assistant turns only carry it).
            if let usage = msg["usage"] as? [String: Any] {
                totals.add(usage)
            }

            // Scan content blocks for text / tool_use.
            if let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    let btype = block["type"] as? String
                    switch btype {
                    case "text":
                        if let t = block["text"] as? String,
                           !t.isEmpty,
                           msg["role"] as? String == "assistant" {
                            lastAssistantText = t
                        } else if let t = block["text"] as? String,
                                  msg["role"] as? String == "user",
                                  !t.isEmpty,
                                  !t.hasPrefix("<") {
                            lastUserText = t
                        }
                    case "tool_use":
                        if let name = block["name"] as? String {
                            lastToolUseName = name
                            lastToolUseInput = block["input"] as? [String: Any]
                            // Capture todos when this is the TodoWrite tool.
                            if name == "TodoWrite",
                               let input = block["input"] as? [String: Any],
                               let todos = input["todos"] as? [[String: Any]] {
                                lastTodos = todos
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }

        snap.cwd = cwd
        snap.model = model
        snap.note = nil

        // State heuristic: assistant turn very recently → running; otherwise idle.
        let ageSec = -pick.mtime.timeIntervalSinceNow
        if ageSec < 3                          { snap.state = .running }
        else if lastRecordRole == "user"       { snap.state = .awaiting }
        else if ageSec > 300                   { snap.state = .stale }
        else                                   { snap.state = .idle }

        // Current task = first TODO with status == in_progress.
        if let active = lastTodos.first(where: { ($0["status"] as? String) == "in_progress" }),
           let title = active["content"] as? String {
            snap.currentTask = title
        }

        // Last tool action, formatted "Tool target".
        if let name = lastToolUseName {
            snap.lastTool = describe(tool: name, input: lastToolUseInput)
        }

        // Last text fallback (used when no task/tool).
        snap.lastText = lastAssistantText ?? lastUserText

        // Token-based context % and cost.
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

        // Git for the project's cwd.
        if let c = cwd, let info = Git.info(cwd: c) {
            snap.branch = info.branch
            snap.dirtyCount = info.dirty
        }

        return snap
    }

    /// Render "Edit Panel.swift", "Bash ls -la", "Read x.txt" etc.
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

/// Running token totals across the parsed tail. The "in-context" value is the
/// LAST observed turn's input + cache_read + cache_creation (what was paid for
/// to keep loaded), since prior turns rolled into cache_read.
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
