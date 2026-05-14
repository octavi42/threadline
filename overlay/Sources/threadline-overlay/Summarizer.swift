import Foundation

/// Generates 1-2 sentence "what this session is about" summaries via the
/// Anthropic Messages API. Cached on disk by (jsonlPath, mtime) so we only
/// pay for it once per significant change.
///
/// Configure with EITHER:
///   • env var `ANTHROPIC_API_KEY`
///   • `~/.threadline/config.json` with `{ "anthropic_api_key": "sk-ant-..." }`
///
/// If neither is set, summaries are skipped (consumer gets nil).
final class Summarizer {
    static let shared = Summarizer()

    private struct CacheEntry {
        let mtime: Date
        let text: String
    }

    private var memory: [String: CacheEntry] = [:]
    private var inflight: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "threadline.summarizer", qos: .utility)

    private var cacheDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.threadline/cache"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Look up the summary for a JSONL. Returns the cached text if fresh;
    /// otherwise triggers an async fetch and returns nil. `onUpdate` is
    /// invoked on the main thread when the summary lands.
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
            lock.unlock()
            return memory[path]?.text   // serve stale text while a fresh fetch runs
        }
        inflight.insert(path)
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
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
        // Hash the path so the cache filename stays bounded.
        var hash: UInt64 = 14695981039346656037
        for byte in jsonlPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "\(cacheDir)/\(String(hash, radix: 16)).summary.json"
    }

    // MARK: - API call

    private func fetchAndCache(path: String, mtime: Date) -> String? {
        guard let key = readAPIKey() else { return nil }
        guard let body = buildPrompt(from: path) else { return nil }
        guard let summary = postToAnthropic(apiKey: key, userContent: body) else { return nil }
        let entry = CacheEntry(mtime: mtime, text: summary)
        lock.lock()
        memory[path] = entry
        lock.unlock()
        saveDisk(path: path, entry: entry)
        return summary
    }

    private func readAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !env.isEmpty { return env }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.threadline/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["anthropic_api_key"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Tail the JSONL and extract human-readable user/assistant text. We
    /// strip tool_use noise so the summarizer focuses on the conversation.
    private func buildPrompt(from path: String) -> String? {
        guard let tail = tailOfFile(path: path, maxBytes: 32 * 1024) else { return nil }
        var snippets: [String] = []
        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Claude shape
            if let msg = obj["message"] as? [String: Any] {
                let role = msg["role"] as? String ?? ""
                if let content = msg["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text",
                           let t = block["text"] as? String, !t.isEmpty,
                           !t.hasPrefix("<") {
                            snippets.append("\(role): \(t)")
                        }
                    }
                } else if let text = msg["content"] as? String, !text.isEmpty {
                    snippets.append("\(role): \(text)")
                }
                continue
            }
            // Codex shape (event_msg agent_message / user_message)
            if obj["type"] as? String == "event_msg",
               let payload = obj["payload"] as? [String: Any] {
                let etype = payload["type"] as? String
                if (etype == "agent_message" || etype == "user_message"),
                   let m = payload["message"] as? String, !m.isEmpty {
                    let role = etype == "user_message" ? "user" : "assistant"
                    snippets.append("\(role): \(m)")
                }
            }
        }
        if snippets.isEmpty { return nil }
        // Keep the most recent ~20 turns and clip per-turn length.
        let kept = snippets.suffix(20).map { $0.prefix(800) }.map(String.init)
        return kept.joined(separator: "\n\n")
    }

    private func postToAnthropic(apiKey: String, userContent: String) -> String? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let payload: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 160,
            "system": "You summarize coding-assistant sessions in 1–2 short sentences. Focus on what the developer is working on and the current intent. No fluff, no preamble.",
            "messages": [
                ["role": "user", "content": userContent]
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var responseText: String?
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? [[String: Any]] else { return }
            let texts = content.compactMap { $0["text"] as? String }
            let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { responseText = joined }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return responseText
    }
}
