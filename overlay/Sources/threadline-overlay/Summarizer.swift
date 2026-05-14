import Foundation

/// Generates 1-2 sentence "what this session is about" summaries.
///
/// Auth model: shells out to the user's installed `claude` (`-p` print mode)
/// or `codex` (`exec` non-interactive) CLI. That CLI uses whatever auth the
/// user already configured — Pro/Max subscription via OAuth, keychain
/// credential, or API key — so no separate API key has to be set, and the
/// (tiny) cost goes against the user's existing plan.
///
/// Fallback order:
///   1. `claude -p --model haiku` (cheapest, fast)
///   2. `codex exec` (if claude isn't installed)
///   3. Anthropic Messages API directly if `ANTHROPIC_API_KEY` is set
///   4. nil — Summary tab shows a "no summarizer available" hint
///
/// Cached on disk by (jsonlPath, mtime) so each session only summarises once
/// per significant change.
final class Summarizer {
    static let shared = Summarizer()

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

    private static let summaryPrompt =
        "Summarize this coding-assistant session in 1–2 short sentences. " +
        "Focus on what the developer is working on and the current intent. " +
        "No preamble, no fluff."

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
                 onUpdate: @escaping (String) -> Void) -> String? {
        lock.lock()
        if let hit = memory[path], hit.mtime == mtime {
            lock.unlock()
            return hit.text
        }
        if let disk = loadDisk(path: path), disk.mtime == mtime {
            memory[path] = disk
            lock.unlock()
            return disk.text
        }
        if inflight.contains(path) {
            let stale = memory[path]?.text
            lock.unlock()
            return stale
        }
        inflight.insert(path)
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            self.processSemaphore.wait()
            defer { self.processSemaphore.signal() }
            let text = self.fetchAndCache(path: path, mtime: mtime)
            self.lock.lock()
            self.inflight.remove(path)
            self.lock.unlock()
            if let text = text {
                DispatchQueue.main.async { onUpdate(text) }
            }
        }
        return memory[path]?.text
    }

    // MARK: - dispatch

    private func fetchAndCache(path: String, mtime: Date) -> String? {
        guard let content = buildPrompt(from: path) else { return nil }

        // Pull the prior summary (any mtime) so the prompt can evolve it
        // instead of starting fresh from the sliding window.
        lock.lock()
        let previous = memory[path]?.text ?? loadDisk(path: path)?.text
        lock.unlock()

        let summary = runClaudeCLI(content: content, previous: previous)
                   ?? runCodexCLI(content: content, previous: previous)
                   ?? runAnthropicAPI(content: content, previous: previous)
        guard let text = summary, !text.isEmpty else { return nil }
        let entry = CacheEntry(mtime: mtime, text: text)
        lock.lock()
        memory[path] = entry
        lock.unlock()
        saveDisk(path: path, entry: entry)
        return text
    }

    private func promptWithContinuity(previous: String?) -> String {
        guard let prev = previous?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prev.isEmpty else {
            return Summarizer.summaryPrompt
        }
        return Summarizer.summaryPrompt
            + "\n\nThe previous summary was: \"\(prev)\". "
            + "Evolve it to reflect the latest activity below — keep what's still true, update what changed. "
            + "If nothing meaningful changed, return the previous summary unchanged."
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
            "max_tokens": 160,
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
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
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
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")

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

    /// Read the JSONL tail and extract human-readable user/assistant text,
    /// stripping tool-use noise. Caps total length so the model doesn't
    /// receive megabytes of context.
    private func buildPrompt(from path: String) -> String? {
        guard let tail = tailOfFile(path: path, maxBytes: 32 * 1024) else { return nil }
        var snippets: [String] = []
        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let msg = obj["message"] as? [String: Any] {
                let role = msg["role"] as? String ?? ""
                if let content = msg["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text",
                           let t = block["text"] as? String,
                           !t.isEmpty, !t.hasPrefix("<") {
                            snippets.append("\(role): \(t)")
                        }
                    }
                } else if let text = msg["content"] as? String, !text.isEmpty {
                    snippets.append("\(role): \(text)")
                }
                continue
            }
            if obj["type"] as? String == "event_msg",
               let payload = obj["payload"] as? [String: Any] {
                let et = payload["type"] as? String
                if (et == "agent_message" || et == "user_message"),
                   let m = payload["message"] as? String, !m.isEmpty {
                    let role = et == "user_message" ? "user" : "assistant"
                    snippets.append("\(role): \(m)")
                }
            }
        }
        if snippets.isEmpty { return nil }
        let kept = snippets.suffix(20).map { $0.prefix(800) }.map(String.init)
        return kept.joined(separator: "\n\n")
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

    private func cacheFilePath(for jsonlPath: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in jsonlPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "\(cacheDir)/\(String(hash, radix: 16)).summary.json"
    }
}
