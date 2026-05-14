import Foundation

enum CodexSource {
    static func read() -> SourceSnapshot {
        let fm = FileManager.default
        let root = (fm.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".codex/sessions")
        var snap = SourceSnapshot(id: "codex", tool: "Codex")

        // Find newest .jsonl recursively (skip the legacy flat .json files).
        guard let url = newestJSONL(under: URL(fileURLWithPath: root)) else {
            snap.status = "no session"
            return snap
        }
        if let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
            snap.updatedAt = m
        }
        snap.status = "ok"

        guard let tail = tailOfFile(path: url.path, maxBytes: 48 * 1024) else {
            return snap
        }
        var meta: (cwd: String?, model: String?)?
        var lastAssistant: (text: String, ts: Date?)?
        var lastUser: (text: String, ts: Date?)?

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = rec["type"] as? String ?? ""
            let payload = rec["payload"] as? [String: Any] ?? [:]
            let ts = (rec["timestamp"] as? String).flatMap(ClaudeSource.parseISO)

            switch type {
            case "session_meta":
                meta = (payload["cwd"] as? String,
                        (payload["model"] as? String) ?? (payload["model_provider"] as? String))
            case "event_msg":
                if payload["type"] as? String == "agent_message",
                   let msg = payload["message"] as? String, !msg.isEmpty {
                    lastAssistant = (msg, ts)
                } else if payload["type"] as? String == "user_message",
                          let msg = payload["message"] as? String, !msg.isEmpty {
                    lastUser = (msg, ts)
                }
            case "response_item":
                if payload["type"] as? String == "message" {
                    let role = payload["role"] as? String
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { ($0["text"] as? String) }.joined(separator: " ")
                    if !text.isEmpty {
                        if role == "assistant" { lastAssistant = (text, ts) }
                        else if role == "user" { lastUser = (text, ts) }
                    }
                }
            default:
                break
            }
        }

        // Head-of-file metadata (cwd/model) if tail missed it.
        if meta == nil, let head = headOfFile(path: url.path, maxBytes: 8 * 1024) {
            for raw in head.split(separator: "\n", omittingEmptySubsequences: true) {
                if let data = raw.data(using: .utf8),
                   let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   rec["type"] as? String == "session_meta",
                   let p = rec["payload"] as? [String: Any] {
                    meta = (p["cwd"] as? String, p["model"] as? String)
                    break
                }
            }
        }

        snap.cwd = meta?.cwd
        snap.model = meta?.model
        if let a = lastAssistant {
            snap.lastRole = "assistant"; snap.lastText = a.text
            if let t = a.ts { snap.updatedAt = t }
        } else if let u = lastUser {
            snap.lastRole = "user"; snap.lastText = u.text
            if let t = u.ts { snap.updatedAt = t }
        }
        return snap
    }

    private static func newestJSONL(under root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles])
        else { return nil }
        var best: (URL, Date)?
        for case let u as URL in enumerator {
            guard u.pathExtension == "jsonl" else { continue }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true, let m = v?.contentModificationDate else { continue }
            if best == nil || m > best!.1 { best = (u, m) }
        }
        return best?.0
    }
}

func headOfFile(path: String, maxBytes: Int) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let data = fh.readData(ofLength: maxBytes)
    return String(data: data, encoding: .utf8)
}
