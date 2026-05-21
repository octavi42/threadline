import Foundation

/// Generates a short session brief for the Overview tab (goal, progress, files).
///
/// Auth model: shells out to the user's installed `claude` (`-p` print mode)
/// or `codex` (`exec` non-interactive) CLI. That CLI uses whatever auth the
/// user already configured — Pro/Max subscription via OAuth, keychain
/// credential, or API key — so no separate API key has to be set, and the
/// (tiny) cost goes against the user's existing plan.
///
/// Fallback order:
///   1. Local Ollama (`THREADLINE_OLLAMA_*` / `~/.threadline/config.json`)
///   2. `claude -p --model haiku` (cheapest, fast)
///   3. `codex exec` (if claude isn't installed)
///   4. Anthropic Messages API directly if `ANTHROPIC_API_KEY` is set
///   5. nil — Overview shows a structural brief from snapshot metadata
///
/// Cached on disk by (jsonlPath, mtime) so each session only summarises once
/// per significant change.
struct SummaryContext: Equatable {
    let projectName: String
    let currentTask: String?
    let lastTool: String?
    let filesEdited: [String]
    let activityLine: String
}

final class Summarizer {
    static let shared = Summarizer()

    private init() {
        purgeOldCacheVersions()
    }

    /// Remove cache files written by older prompt/extraction versions so we
    /// don't slowly accumulate dead `.v1.summary.json` etc. on disk.
    private func purgeOldCacheVersions() {
        let fm = FileManager.default
        let dir = cacheDir
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let activeSuffix = ".v\(Summarizer.cacheVersion).summary.json"
        for name in entries where name.hasSuffix(".summary.json") && !name.hasSuffix(activeSuffix) {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }

    private struct CacheEntry {
        let mtime: Date
        let text: String
    }

    private var memory: [String: CacheEntry] = [:]
    private var inflight: Set<String> = []
    private let lock = NSLock()
    /// Concurrent so multiple sessions can summarise in parallel.
    private let queue = DispatchQueue(label: "threadline.summarizer",
                                      qos: .utility,
                                      attributes: .concurrent)
    /// Cap how many `claude -p` / `codex exec` processes run at once.
    private let processSemaphore = DispatchSemaphore(value: 2)

    private static let briefPrompt =
        "Write a session brief so a developer returning later understands this " +
        "coding session. Use 2-3 short sentences (max 45 words total). Sentence 1: " +
        "what they asked the agent to work on (the goal). Sentence 2: what changed " +
        "recently — name files or features. Optional sentence 3: blockers or next step " +
        "only if obvious. Plain language. Never start with \"I've made the following " +
        "changes\" or describe summarization/Threadline internals."

    private var cacheDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.threadline/cache"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Look up the summary for a JSONL. Returns the cached text if fresh;
    /// otherwise triggers an async fetch and returns the previous text (or
    /// nil). `onUpdate` fires on main when a fresh summary lands.
    func summary(forJSONL path: String,
                 mtime: Date,
                 context: SummaryContext? = nil,
                 onUpdate: @escaping (String) -> Void) -> String? {
        lock.lock()
        if let hit = memory[path], hit.mtime == mtime {
            lock.unlock()
            return SourceSnapshot.normalizeBrief(hit.text)
        }
        if let disk = loadDisk(path: path), disk.mtime == mtime {
            let normalized = SourceSnapshot.normalizeBrief(disk.text)
            memory[path] = CacheEntry(mtime: disk.mtime, text: normalized)
            lock.unlock()
            return normalized
        }
        if inflight.contains(path) {
            let stale = memory[path].map { SourceSnapshot.normalizeBrief($0.text) }
            lock.unlock()
            return stale
        }
        inflight.insert(path)
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            self.processSemaphore.wait()
            defer { self.processSemaphore.signal() }
            let text = self.fetchAndCache(path: path, mtime: mtime, context: context)
            self.lock.lock()
            self.inflight.remove(path)
            self.lock.unlock()
            if let text = text {
                DispatchQueue.main.async { onUpdate(text) }
            }
        }
        return memory[path].map { SourceSnapshot.normalizeBrief($0.text) }
    }

    // MARK: - dispatch

    private func fetchAndCache(path: String, mtime: Date, context: SummaryContext?) -> String? {
        let openingGoal = Self.extractOpeningGoal(from: path)
        guard let content = buildPrompt(from: path, context: context) else {
            return Self.structuralFallback(context: context, openingGoal: openingGoal)
        }

        // Pull the prior summary (any mtime) so the prompt can evolve it
        // instead of starting fresh from the sliding window.
        lock.lock()
        let previous = memory[path]?.text ?? loadDisk(path: path)?.text
        lock.unlock()
        let safePrevious = previous.flatMap { Self.isLowQuality($0) ? nil : $0 }

        let summary = firstAcceptedBrief(
            content: content,
            previous: safePrevious,
            context: context,
            openingGoal: openingGoal
        )
        guard let text = summary, !text.isEmpty else { return nil }
        let normalized = SourceSnapshot.normalizeBrief(text)
        let entry = CacheEntry(mtime: mtime, text: normalized)
        lock.lock()
        memory[path] = entry
        lock.unlock()
        saveDisk(path: path, entry: entry)
        return normalized
    }

    private func promptWithContinuity(previous: String?) -> String {
        guard let prev = previous?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prev.isEmpty else {
            return Summarizer.briefPrompt
        }
        return Summarizer.briefPrompt
            + "\n\nThe previous brief was: \"\(prev)\". "
            + "Update it from the latest turns below. "
            + "If nothing meaningful changed, return the previous brief unchanged."
    }

    /// Try each LLM backend; use the first response that passes quality checks.
    private func firstAcceptedBrief(content: String,
                                    previous: String?,
                                    context: SummaryContext?,
                                    openingGoal: String?) -> String? {
        let runners: [() -> String?] = [
            { self.runOllama(content: content, previous: previous) },
            { self.runClaudeCLI(content: content, previous: previous) },
            { self.runCodexCLI(content: content, previous: previous) },
            { self.runAnthropicAPI(content: content, previous: previous) },
        ]
        for run in runners {
            if let raw = run(), let accepted = Self.acceptedBrief(raw) {
                return accepted
            }
        }
        return Self.structuralFallback(context: context, openingGoal: openingGoal)
    }

    // MARK: - Ollama (local)

    private func runOllama(content: String, previous: String?) -> String? {
        LocalLLM.complete(system: promptWithContinuity(previous: previous),
                          user: content,
                          maxTokens: 120,
                          timeout: 25)
    }

    // MARK: - claude -p

    private func runClaudeCLI(content: String, previous: String?) -> String? {
        guard let exe = which("claude") else { return nil }
        let args = [
            "-p", promptWithContinuity(previous: previous),
            "--model", "haiku",
            "--output-format", "text",
            "--no-session-persistence",
        ]
        return runProcess(exe: exe, args: args, stdin: content, timeout: 25)
    }

    // MARK: - codex exec

    private func runCodexCLI(content: String, previous: String?) -> String? {
        guard let exe = which("codex") else { return nil }
        let args = ["exec", promptWithContinuity(previous: previous)]
        return runProcess(exe: exe, args: args, stdin: content, timeout: 30)
    }

    // MARK: - Anthropic API (final fallback)

    private func runAnthropicAPI(content: String, previous: String?) -> String? {
        guard let key = readAPIKey() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json",  forHTTPHeaderField: "content-type")
        req.setValue(key,                 forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        let payload: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 120,
            "system": promptWithContinuity(previous: previous),
            "messages": [["role": "user", "content": content]],
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

    // MARK: - process helpers

    private func which(_ binary: String) -> String? {
        // Common install locations the daemon's PATH may not include because
        // launchd starts us with a minimal environment.
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
        // Last resort: ask the shell.
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

        // Bound wait — kill if it overruns the timeout.
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

    // MARK: - prompt building

    /// Read the shared normalized transcript and build a summary prompt. If
    /// the total exceeds the prompt budget, keep the head and the tail with an
    /// ellipsis between so the LLM sees both how the session opened and the
    /// recent activity.
    private func buildPrompt(from path: String, context: SummaryContext?) -> String? {
        let transcriptText = SessionTranscriptCache.activeTranscript(fromJSONL: path)?.summaryText
            ?? SessionTranscriptCache.transcript(fromJSONL: path)?.summaryText
        if transcriptText == nil, context == nil { return nil }

        var parts: [String] = []
        if let ctx = context {
            parts.append(Self.contextHeader(ctx))
        }
        if let transcriptText = transcriptText, !transcriptText.isEmpty {
            parts.append(transcriptText)
        }
        let joined = parts.joined(separator: "\n\n---\n\n")
        if joined.isEmpty { return nil }

        // Cap per-snippet length so a single huge turn can't blow the budget.
        let trimmed = joined.split(separator: "\n\n", omittingEmptySubsequences: true)
            .map { String($0.prefix(2000)) }
        let body = trimmed.joined(separator: "\n\n")

        // Total budget: ~100 KB of text (~25K tokens — well within haiku's
        // 200K context window with room for the system prompt + response).
        let maxBytes = 100 * 1024
        if body.utf8.count <= maxBytes { return body }

        // Too long: keep first 20% + last 80%, with an ellipsis between, so
        // the LLM sees the framing and the recent arc.
        let headBytes = maxBytes / 5
        let tailBytes = maxBytes - headBytes - 32
        let head = String(body.prefix(headBytes))
        let tail = String(body.suffix(tailBytes))
        return head + "\n\n[…earlier turns omitted…]\n\n" + tail
    }

    // MARK: - quality helpers (testable)

    /// Cursor sessions use structured evidence; LLM runs when the active segment
    /// has enough tool trace or dialogue to summarize meaningfully.
    static func shouldSummarize(tool: String, jsonlPath: String) -> Bool {
        if tool == "Cursor" {
            guard let active = SessionTranscriptCache.activeTranscript(fromJSONL: jsonlPath) else {
                return false
            }
            if !active.toolLines.isEmpty { return true }
            return active.snippets.count >= 2
        }
        return !isMostlyRedacted(jsonlPath: jsonlPath)
    }

    static func isMostlyRedacted(jsonlPath: String, maxBytes: Int = 96 * 1024) -> Bool {
        guard let tail = tailOfFile(path: jsonlPath, maxBytes: maxBytes), !tail.isEmpty else {
            return true
        }
        let redactedHits = tail.components(separatedBy: "[REDACTED]").count - 1
        if redactedHits == 0 { return false }
        let assistantLines = tail.split(separator: "\n")
            .filter { $0.contains("\"role\":\"assistant\"") }
            .count
        if assistantLines == 0 { return redactedHits >= 2 }
        return Double(redactedHits) / Double(assistantLines) >= 0.5
    }

    static func shouldDiscardSnippet(_ text: String) -> Bool {
        SessionTranscript.shouldDiscardSnippet(text)
    }

    static func isLowQuality(_ summary: String) -> Bool {
        let lower = summary.lowercased()
        let fluff = [
            "the current state of the project",
            "the project's current focus",
            "involves several key components",
            "these elements are crucial",
            "ensuring a seamless integration",
            "i've made the current session text",
            "i've made the following changes",
            "more concise by limiting",
            "arrays to views like",
            "snap.tasksdone",
            "linesadded",
            "linesremoved",
            "ai coding agents, keeping track",
            "session text in the",
        ]
        if fluff.contains(where: { lower.contains($0) }) { return true }
        if lower.hasPrefix("the ") && lower.contains(" involves ") { return true }
        return false
    }

    static func structuralFallback(context: SummaryContext?, openingGoal: String? = nil) -> String? {
        guard let ctx = context else { return nil }
        var sentences: [String] = []

        if let goal = openingGoal?.trimmingCharacters(in: .whitespacesAndNewlines),
           !goal.isEmpty {
            sentences.append("Goal: \(SourceSnapshot.compactLine(goal, limit: 140, maxWords: 22, firstSentence: false)).")
        } else if let task = ctx.currentTask?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !task.isEmpty {
            sentences.append("Goal: \(SourceSnapshot.compactLine(task, limit: 140, maxWords: 22, firstSentence: false)).")
        }

        if !ctx.filesEdited.isEmpty {
            let names = ctx.filesEdited.suffix(4).map { ($0 as NSString).lastPathComponent }
            sentences.append("Edited \(names.joined(separator: ", ")).")
        }

        if let tool = ctx.lastTool?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tool.isEmpty {
            sentences.append("Latest: \(SourceSnapshot.compactLine(tool, limit: 120, maxWords: 18, firstSentence: false)).")
        } else if ctx.activityLine != "—" {
            sentences.append(SourceSnapshot.compactLine(ctx.activityLine, limit: 140, maxWords: 22, firstSentence: false) + ".")
        }

        guard !sentences.isEmpty else { return nil }
        return SourceSnapshot.normalizeBrief(sentences.joined(separator: " "))
    }

    /// Rich deterministic brief from active-segment tool trace (Cursor-friendly).
    static func structuredEvidenceBrief(for snap: SourceSnapshot) -> String? {
        guard let path = snap.jsonlPath,
              let active = SessionTranscriptCache.activeTranscript(fromJSONL: path)
        else { return nil }

        var sentences: [String] = []
        if let goal = active.openingGoal {
            sentences.append("Goal: \(SourceSnapshot.compactLine(goal, limit: 140, maxWords: 22, firstSentence: false)).")
        } else if let ask = active.latestUserAsk {
            sentences.append("Goal: \(SourceSnapshot.compactLine(ask, limit: 140, maxWords: 22, firstSentence: false)).")
        }

        let edits = snap.filesEdited.suffix(4).map { ($0 as NSString).lastPathComponent }
        if !edits.isEmpty {
            sentences.append("Edited \(edits.joined(separator: ", ")).")
        }

        let trace = active.toolLines.suffix(6)
        if !trace.isEmpty {
            let joined = trace.joined(separator: "; ")
            sentences.append("Activity: \(SourceSnapshot.compactLine(joined, limit: 160, maxWords: 24, firstSentence: false)).")
        } else if let tool = snap.lastTool, !tool.isEmpty {
            sentences.append("Latest: \(SourceSnapshot.compactLine(tool, limit: 120, maxWords: 18, firstSentence: false)).")
        }

        guard !sentences.isEmpty else { return nil }
        return SourceSnapshot.normalizeBrief(sentences.joined(separator: " "))
    }

    static func extractOpeningGoal(from path: String) -> String? {
        SessionTranscriptCache.activeOpeningGoal(fromJSONL: path)
            ?? SessionTranscriptCache.transcript(fromJSONL: path)?.openingGoal
    }

    private static func substantiveUserText(_ text: String) -> String? {
        SessionTranscript.substantiveUserText(text)
    }

    static func acceptedBrief(_ llm: String) -> String? {
        let trimmed = llm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLowQuality(trimmed) else { return nil }
        return trimmed
    }

    private static func contextHeader(_ ctx: SummaryContext) -> String {
        var lines = ["project: \(ctx.projectName)"]
        if !ctx.filesEdited.isEmpty {
            let names = ctx.filesEdited.suffix(4).map { ($0 as NSString).lastPathComponent }
            lines.append("files_edited: \(names.joined(separator: ", "))")
        }
        if let task = ctx.currentTask, !task.isEmpty {
            lines.append("current_task: \(task)")
        }
        if let tool = ctx.lastTool, !tool.isEmpty {
            lines.append("last_action: \(tool)")
        }
        return lines.joined(separator: "\n")
    }

    private static func toolUseLine(_ block: [String: Any]) -> String? {
        guard let name = block["name"] as? String else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        if let path = input["file_path"] as? String {
            return "\(name) \((path as NSString).lastPathComponent)"
        }
        if let cmd = input["command"] as? String {
            let first = cmd.split(separator: "\n").first.map(String.init) ?? cmd
            return "\(name) \(first)"
        }
        if let subject = input["subject"] as? String {
            return "\(name) \(subject)"
        }
        return name
    }

    // MARK: - disk cache

    private func loadDisk(path: String) -> CacheEntry? {
        let cachePath = cacheFilePath(for: path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String,
              let mtimeSec = obj["mtime"] as? Double
        else { return nil }
        return CacheEntry(mtime: Date(timeIntervalSince1970: mtimeSec), text: text)
    }

    private func saveDisk(path: String, entry: CacheEntry) {
        let cachePath = cacheFilePath(for: path)
        let obj: [String: Any] = [
            "text": entry.text,
            "mtime": entry.mtime.timeIntervalSince1970,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: []) {
            try? data.write(to: URL(fileURLWithPath: cachePath))
        }
    }

    /// Bump when the prompt or extraction logic changes — old cache entries
    /// then naturally turn into cache misses and get re-generated.
    private static let cacheVersion = 6

    private func cacheFilePath(for jsonlPath: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in jsonlPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "\(cacheDir)/\(String(hash, radix: 16)).v\(Summarizer.cacheVersion).summary.json"
    }
}
