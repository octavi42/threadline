import Foundation

enum CodexSource {
    static func read(scopeCwd: String? = nil) -> SourceSnapshot {
        let fm = FileManager.default
        let root = (fm.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".codex/sessions")
        var snap = SourceSnapshot(id: "codex", tool: "Codex", badge: "CDX")

        // Prefer a session whose `session_meta.cwd` matches the scope cwd.
        // Scan the top-N newest jsonls and check their head; fall back to
        // global newest if none match.
        guard let url = newestJSONL(under: URL(fileURLWithPath: root),
                                    scopeCwd: scopeCwd) else {
            snap.state = .none; snap.note = "no session"
            return snap
        }
        if let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
            snap.updatedAt = m
        }

        guard let tail = tailOfFile(path: url.path, maxBytes: 64 * 1024) else { return snap }

        var cwd: String?
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
                cwd = payload["cwd"] as? String
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
                if etype == "task_started", let cw = payload["context_window"] as? Int {
                    contextLimit = cw
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
            default:
                break
            }
        }

        snap.cwd = cwd
        snap.model = model
        snap.lastText = lastAssistant ?? lastUser

        let ageSec = snap.updatedAt.map { -$0.timeIntervalSinceNow } ?? 999_999
        if sawStartedAfterComplete && ageSec < 30 { snap.state = .running }
        else if ageSec < 5                          { snap.state = .running }
        else if ageSec > 300                        { snap.state = .stale }
        else                                        { snap.state = .idle }

        if let u = lastTokenUsage, let limit = contextLimit, limit > 0 {
            snap.contextPercent = min(1.0, Double(u.input + u.cached) / Double(limit))
        }

        if let c = cwd, let info = Git.info(cwd: c) {
            snap.branch = info.branch
            snap.dirtyCount = info.dirty
        }
        return snap
    }

    private static func newestJSONL(under root: URL, scopeCwd: String?) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles])
        else { return nil }
        var all: [(URL, Date)] = []
        for case let u as URL in enumerator {
            guard u.pathExtension == "jsonl" else { continue }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true, let m = v?.contentModificationDate else { continue }
            all.append((u, m))
        }
        all.sort { $0.1 > $1.1 }

        // No scope → newest globally.
        guard let scope = scopeCwd, !scope.isEmpty else { return all.first?.0 }

        // With scope: read head of top-N to find one whose session_meta.cwd
        // is at or below the scope cwd.
        let candidates = all.prefix(20)
        for (url, _) in candidates {
            if let head = headOfFile(path: url.path, maxBytes: 4 * 1024) {
                for raw in head.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let data = String(raw).data(using: .utf8),
                          let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          rec["type"] as? String == "session_meta",
                          let payload = rec["payload"] as? [String: Any],
                          let metaCwd = payload["cwd"] as? String
                    else { continue }
                    if metaCwd == scope || metaCwd.hasPrefix(scope + "/") {
                        return url
                    }
                    break  // first record is always session_meta; no point reading more
                }
            }
        }
        return all.first?.0
    }
}
