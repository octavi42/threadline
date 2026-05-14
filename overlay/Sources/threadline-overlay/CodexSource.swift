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
        guard let head = headOfFile(path: url.path, maxBytes: 4 * 1024) else { return nil }
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

    private static func snapshot(at url: URL, mtime: Date, knownCwd: String) -> SourceSnapshot? {
        var snap = SourceSnapshot(id: "codex:\(knownCwd)",
                                  tool: "Codex",
                                  badge: "CDX")
        snap.updatedAt = mtime
        snap.cwd = knownCwd

        guard let tail = tailOfFile(path: url.path, maxBytes: 64 * 1024) else { return snap }

        var model: String?
        var contextLimit: Int?
        var lastAssistant: String?
        var lastUser: String?
        var lastTokenUsage: (input: Int, cached: Int, output: Int)?
        var sawStartedAfterComplete = false

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
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
                if payload["type"] as? String == "message" {
                    let role = payload["role"] as? String
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                    if !text.isEmpty {
                        if role == "assistant" { lastAssistant = text }
                        else if role == "user" { lastUser = text }
                    }
                }
            default: break
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
        return snap
    }
}
