import Foundation

enum ClaudeSource {
    static func read() -> SourceSnapshot {
        let fm = FileManager.default
        let root = (fm.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".claude/projects")
        var snap = SourceSnapshot(id: "claude", tool: "Claude")

        guard let projects = try? fm.contentsOfDirectory(atPath: root) else {
            snap.status = "no session"
            return snap
        }

        // Find newest JSONL across all project subdirs.
        var newest: (path: String, mtime: Date)?
        for proj in projects {
            let projDir = (root as NSString).appendingPathComponent(proj)
            guard let files = try? fm.contentsOfDirectory(atPath: projDir) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let path = (projDir as NSString).appendingPathComponent(f)
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let m = attrs[.modificationDate] as? Date {
                    if newest == nil || m > newest!.mtime {
                        newest = (path, m)
                    }
                }
            }
        }
        guard let pick = newest else {
            snap.status = "no session"
            return snap
        }
        snap.updatedAt = pick.mtime
        snap.status = "ok"

        // Read the tail of the file (last ~32KB) and parse JSONL lines.
        guard let tail = tailOfFile(path: pick.path, maxBytes: 32 * 1024) else {
            return snap
        }
        var lastAssistant: (text: String, model: String?, cwd: String?, ts: Date?)?
        var lastUser: (text: String, cwd: String?, ts: Date?)?
        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let type = obj["type"] as? String else { continue }
            let cwd = obj["cwd"] as? String
            let ts = (obj["timestamp"] as? String).flatMap(Self.parseISO)
            if type == "user" || type == "assistant",
               let msg = obj["message"] as? [String: Any] {
                let role = msg["role"] as? String ?? type
                let model = msg["model"] as? String
                let text = extractText(msg["content"]) ?? ""
                if role == "assistant" && !text.isEmpty {
                    lastAssistant = (text, model, cwd, ts)
                } else if role == "user" && !text.isEmpty && !text.hasPrefix("<") {
                    lastUser = (text, cwd, ts)
                }
            }
        }
        if let a = lastAssistant {
            snap.lastRole = "assistant"
            snap.lastText = a.text
            snap.model = a.model
            snap.cwd = a.cwd
            if let t = a.ts { snap.updatedAt = t }
        } else if let u = lastUser {
            snap.lastRole = "user"
            snap.lastText = u.text
            snap.cwd = u.cwd
            if let t = u.ts { snap.updatedAt = t }
        }
        return snap
    }

    /// Claude content blocks: [{type: "text", text: "..."}, {type: "tool_use", ...}, ...]
    /// We return the concatenated text blocks.
    private static func extractText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return nil }
        var out: [String] = []
        for block in arr {
            if block["type"] as? String == "text", let t = block["text"] as? String {
                out.append(t)
            }
        }
        let joined = out.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Read the last `maxBytes` bytes of a file as UTF-8 (best-effort).
func tailOfFile(path: String, maxBytes: Int) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size: UInt64
    do {
        size = try fh.seekToEnd()
    } catch { return nil }
    let offset: UInt64 = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    do {
        try fh.seek(toOffset: offset)
    } catch { return nil }
    let data = fh.availableData
    return String(data: data, encoding: .utf8)
}
