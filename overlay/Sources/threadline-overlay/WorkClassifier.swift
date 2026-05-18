import Foundation

/// LLM-backed session tagger. It only sees compact evidence, never raw full
/// transcripts, and caches by (jsonl path, mtime) so labels do not re-run on
/// every refresh.
final class WorkClassifier {
    static let shared = WorkClassifier()

    private struct CacheEntry {
        let mtime: Date
        let work: WorkState
    }

    private var memory: [String: CacheEntry] = [:]
    private var inflight: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "threadline.work-classifier",
                                      qos: .utility,
                                      attributes: .concurrent)
    private let processSemaphore = DispatchSemaphore(value: 1)

    private init() {
        purgeOldCacheVersions()
    }

    private func purgeOldCacheVersions() {
        let fm = FileManager.default
        let dir = cacheDir
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let activeSuffix = ".v\(Self.cacheVersion).work.json"
        for name in entries where name.hasSuffix(".work.json") && !name.hasSuffix(activeSuffix) {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }

    func classify(snap: SourceSnapshot,
                  onUpdate: @escaping (WorkState) -> Void) -> WorkState? {
        guard let path = snap.jsonlPath, let mtime = snap.updatedAt else { return nil }

        lock.lock()
        if let hit = memory[path], hit.mtime == mtime {
            lock.unlock()
            return hit.work
        }
        if let disk = loadDisk(path: path), disk.mtime == mtime {
            memory[path] = disk
            lock.unlock()
            return disk.work
        }
        if inflight.contains(path) {
            let stale = memory[path]?.work
            lock.unlock()
            return stale
        }
        inflight.insert(path)
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            self.processSemaphore.wait()
            defer { self.processSemaphore.signal() }
            let work = self.fetchAndCache(snap: snap, path: path, mtime: mtime)
            self.lock.lock()
            self.inflight.remove(path)
            self.lock.unlock()
            if let work = work {
                DispatchQueue.main.async { onUpdate(work) }
            }
        }
        return memory[path]?.work
    }

    private func fetchAndCache(snap: SourceSnapshot, path: String, mtime: Date) -> WorkState? {
        guard let evidence = buildEvidence(snap: snap, path: path) else { return nil }
        guard let work = firstParsedWorkState(from: evidence) else { return nil }
        let entry = CacheEntry(mtime: mtime, work: work)
        lock.lock()
        memory[path] = entry
        lock.unlock()
        saveDisk(path: path, entry: entry)
        return work
    }

    private func buildEvidence(snap: SourceSnapshot, path: String) -> String? {
        guard let tail = tailOfFile(path: path, maxBytes: 128 * 1024) else { return nil }
        var turns: [String] = []
        var tools: [String] = []
        var commandLines: [String] = []
        var patchFiles: Set<String> = []
        var taskStarted = false
        var taskComplete = false

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let message = obj["message"] as? [String: Any] {
                let role = message["role"] as? String ?? ""
                if let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        switch block["type"] as? String {
                        case "text":
                            if let t = block["text"] as? String, !t.hasPrefix("<") {
                                turns.append("\(role): \(compact(t, 900))")
                            }
                        case "tool_use":
                            if let name = block["name"] as? String {
                                tools.append(name)
                                if let input = block["input"] as? [String: Any] {
                                    if let cmd = input["command"] as? String {
                                        commandLines.append(cmd.components(separatedBy: "\n").first ?? cmd)
                                    }
                                    if let file = input["file_path"] as? String {
                                        patchFiles.insert(file)
                                    }
                                }
                            }
                        default:
                            break
                        }
                    }
                }
                continue
            }

            guard let payload = obj["payload"] as? [String: Any] else { continue }
            if obj["type"] as? String == "event_msg" {
                switch payload["type"] as? String {
                case "task_started":
                    taskStarted = true
                    taskComplete = false
                case "task_complete":
                    taskComplete = true
                case "user_message":
                    if let msg = payload["message"] as? String {
                        turns.append("user: \(compact(msg, 900))")
                    }
                case "agent_message":
                    if let msg = payload["message"] as? String {
                        turns.append("assistant: \(compact(msg, 900))")
                    }
                case "patch_apply_end":
                    let changes = payload["changes"] as? [String: Any] ?? [:]
                    for file in changes.keys { patchFiles.insert(file) }
                default:
                    break
                }
            } else if obj["type"] as? String == "response_item" {
                let ptype = payload["type"] as? String
                if ptype == "message" {
                    let role = payload["role"] as? String ?? ""
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { block -> String? in
                        block["text"] as? String ??
                        block["input_text"] as? String ??
                        block["output_text"] as? String
                    }.joined(separator: " ")
                    if !text.isEmpty { turns.append("\(role): \(compact(text, 900))") }
                } else if ptype == "custom_tool_call" || ptype == "function_call" {
                    if let name = payload["name"] as? String {
                        tools.append(name)
                    }
                    let input = String(describing: payload["input"] ?? payload["arguments"] ?? "")
                    if input.contains("exec_command") || input.contains("swift test") ||
                        input.contains("npm test") || input.contains("gh run") {
                        commandLines.append(compact(input, 240))
                    }
                }
            }
        }

        let age = snap.updatedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        let fallback = WorkStatusResolver.resolve(snap)
        let recentTurns = turns.suffix(10).joined(separator: "\n")
        let recentTools = Array(tools.suffix(20)).joined(separator: ", ")
        let commands = Array(commandLines.suffix(12)).joined(separator: "\n")
        let files = Array(Set(snap.filesEdited + snap.fileChanges.map(\.path) + Array(patchFiles)))
            .sorted()
            .prefix(20)
            .joined(separator: "\n")

        return """
        Classify this AI coding session for Threadline's pre-PR inbox.

        Allowed status values exactly:
        Needs you, Tests failed, Stuck, Risky, Ready, Working, Done

        Rules:
        - Working only if there is recent activity and the assistant is currently doing work. A live old process is not enough.
        - Tests failed only if there is actual failed test/CI evidence, not because the words appear in a brainstorm.
        - Ready only if code changed and there is passing test/CI evidence.
        - Risky only if code changed and there is no passing evidence.
        - Needs you for login/auth/usage/approval/user-input blockers.
        - Stuck for repeated identical errors or retry loops.
        - Done for completed research/planning/content sessions or old code sessions that do not need action.

        Return only JSON:
        {"status":"Ready","reason":"short reason","nextAction":"short action"}

        Facts:
        tool: \(snap.tool)
        cwd: \(snap.cwd ?? "unknown")
        state: \(snap.state.rawValue)
        live_pid: \(snap.livePid.map(String.init) ?? "none")
        seconds_since_last_jsonl_update: \(age)
        deterministic_fallback: \(fallback.status.rawValue) - \(fallback.reason)
        files_edited_count: \(max(snap.filesEdited.count, snap.fileChanges.count))
        dirty_count: \(snap.dirtyCount.map(String.init) ?? "unknown")
        lines_added: \(snap.linesAdded)
        lines_removed: \(snap.linesRemoved)
        task_started_without_complete_in_tail: \(taskStarted && !taskComplete)

        Files:
        \(files.isEmpty ? "none" : files)

        Recent tools:
        \(recentTools.isEmpty ? "none" : recentTools)

        Recent commands:
        \(commands.isEmpty ? "none" : commands)

        Recent turns:
        \(recentTurns.isEmpty ? "none" : recentTurns)
        """
    }

    /// Try each backend until one returns parseable classification JSON.
    private func firstParsedWorkState(from evidence: String) -> WorkState? {
        let runners: [() -> String?] = [
            { self.runOllama(evidence: evidence) },
            { self.runClaudeCLI(evidence: evidence) },
            { self.runCodexCLI(evidence: evidence) },
            { self.runAnthropicAPI(evidence: evidence) },
        ]
        for run in runners {
            if let raw = run(), let work = parseWorkState(raw) {
                return work
            }
        }
        return nil
    }

    private func parseWorkState(_ raw: String?) -> WorkState? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusRaw = obj["status"] as? String,
              let status = parseStatus(statusRaw)
        else { return nil }
        let reason = compact((obj["reason"] as? String) ?? status.rawValue, 80)
        let action = compact((obj["nextAction"] as? String) ?? defaultAction(for: status), 40)
        return WorkState(status: status,
                         reason: reason,
                         nextAction: action,
                         rank: rank(for: status))
    }

    private func parseStatus(_ raw: String) -> WorkStatus? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "needs you", "needs_you", "needs-you": return .needsYou
        case "tests failed", "tests_failed", "test failed": return .testsFailed
        case "stuck": return .stuck
        case "risky", "unverified": return .risky
        case "ready", "ready to review": return .ready
        case "working", "still working": return .working
        case "done", "informational": return .done
        default: return nil
        }
    }

    private func rank(for status: WorkStatus) -> Int {
        switch status {
        case .needsYou: return 0
        case .testsFailed: return 1
        case .stuck: return 2
        case .risky: return 3
        case .ready: return 4
        case .working: return 5
        case .done: return 6
        }
    }

    private func defaultAction(for status: WorkStatus) -> String {
        switch status {
        case .needsYou, .stuck: return "Jump back"
        case .testsFailed: return "Inspect failure"
        case .risky: return "Run tests"
        case .ready: return "Review diff"
        case .working: return "Watch"
        case .done: return "Ignore"
        }
    }

    private static let classifySystem = """
        Classify the AI coding session from the user message. \
        Return only one JSON object with keys status, reason, nextAction. \
        status must be one of: Needs you, Tests failed, Stuck, Risky, Ready, Working, Done.
        """

    private func runOllama(evidence: String) -> String? {
        LocalLLM.complete(system: Self.classifySystem,
                          user: evidence,
                          maxTokens: 120,
                          timeout: 20)
    }

    private func runClaudeCLI(evidence: String) -> String? {
        guard let exe = which("claude") else { return nil }
        let prompt = "Classify the session from stdin. Return JSON only."
        let args = ["-p", prompt, "--model", "haiku", "--output-format", "text", "--no-session-persistence"]
        return runProcess(exe: exe, args: args, stdin: evidence, timeout: 25)
    }

    private func runCodexCLI(evidence: String) -> String? {
        guard let exe = which("codex") else { return nil }
        return runProcess(exe: exe,
                          args: ["exec", "Classify the session from stdin. Return JSON only."],
                          stdin: evidence,
                          timeout: 30)
    }

    private func which(_ binary: String) -> String? {
        let candidates: [String] = [
            "/Users/\(NSUserName())/.bun/bin/\(binary)",
            "/Users/\(NSUserName())/.npm-global/bin/\(binary)",
            "/Users/\(NSUserName())/.nvm/versions/node/v22.22.1/bin/\(binary)",
            "/opt/homebrew/bin/\(binary)",
            "/usr/local/bin/\(binary)",
            "/Users/\(NSUserName())/.local/bin/\(binary)",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "which \(binary)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false && FileManager.default.isExecutableFile(atPath: out!)) ? out : nil
    }

    private func readAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !env.isEmpty { return env }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.threadline/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["anthropic_api_key"] as? String, !key.isEmpty
        else { return nil }
        return key
    }

    private func runAnthropicAPI(evidence: String) -> String? {
        guard let key = readAPIKey() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let payload: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 120,
            "system": Self.classifySystem,
            "messages": [["role": "user", "content": evidence]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var responseText: String?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? [[String: Any]] else { return }
            let texts = content.compactMap { $0["text"] as? String }
            let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { responseText = joined }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return responseText
    }

    private func runProcess(exe: String, args: [String], stdin: String, timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        if let data = stdin.data(using: .utf8) {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? inputPipe.fileHandleForWriting.close()

        let group = DispatchGroup()
        group.enter()
        var stdoutData = Data()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let text = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private var cacheDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.threadline/cache"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadDisk(path: String) -> CacheEntry? {
        let cachePath = cacheFilePath(for: path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mtimeSec = obj["mtime"] as? Double,
              let workObj = obj["work"] as? [String: Any],
              let statusRaw = workObj["status"] as? String,
              let status = parseStatus(statusRaw),
              let reason = workObj["reason"] as? String,
              let nextAction = workObj["nextAction"] as? String
        else { return nil }
        return CacheEntry(mtime: Date(timeIntervalSince1970: mtimeSec),
                          work: WorkState(status: status,
                                          reason: reason,
                                          nextAction: nextAction,
                                          rank: rank(for: status)))
    }

    private func saveDisk(path: String, entry: CacheEntry) {
        let cachePath = cacheFilePath(for: path)
        let obj: [String: Any] = [
            "mtime": entry.mtime.timeIntervalSince1970,
            "work": [
                "status": entry.work.status.rawValue,
                "reason": entry.work.reason,
                "nextAction": entry.work.nextAction,
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: URL(fileURLWithPath: cachePath))
        }
    }

    private static let cacheVersion = 2

    private func cacheFilePath(for jsonlPath: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in jsonlPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "\(cacheDir)/\(String(hash, radix: 16)).v\(Self.cacheVersion).work.json"
    }

    private func compact(_ text: String, _ max: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= max { return cleaned }
        return String(cleaned.prefix(max - 1)) + "…"
    }
}
