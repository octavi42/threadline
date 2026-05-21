import Foundation

/// Classifies what the agent is doing in the active session segment.
enum SessionKind: Equatable {
    case research
    case implement
    case debug
    case informational
}

/// Detects `/clear`, `clear`, and Claude `compact_boundary` markers so summaries
/// and work state only consider the active conversation arc.
enum SessionSegment {
    /// Index of the first JSONL line in the active segment (0-based).
    static func activeStartLineIndex(in text: String) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var boundary = 0
        for (index, raw) in lines.enumerated() {
            if isClearBoundaryLine(String(raw)) {
                boundary = index + 1
            } else if isCompactBoundaryLine(String(raw)) {
                boundary = index
            }
        }
        return min(boundary, max(0, lines.count - 1))
    }

    static func activeText(from path: String) -> String? {
        guard let full = try? String(contentsOfFile: path, encoding: .utf8), !full.isEmpty else {
            return nil
        }
        let lines = full.split(separator: "\n", omittingEmptySubsequences: true)
        let start = activeStartLineIndex(in: full)
        guard start < lines.count else { return nil }
        return lines.dropFirst(start).joined(separator: "\n")
    }

    // MARK: - boundaries

    private static func isClearBoundaryLine(_ raw: String) -> Bool {
        guard let obj = parseObject(raw) else { return false }
        let role = obj["role"] as? String ?? obj["type"] as? String ?? ""
        guard role == "user" else { return false }
        guard let message = obj["message"] as? [String: Any] else { return false }

        if let content = message["content"] as? String {
            return isClearCommand(content)
        }
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "text" {
                if let text = block["text"] as? String, isClearCommand(text) { return true }
            }
        }
        return false
    }

    private static func isCompactBoundaryLine(_ raw: String) -> Bool {
        guard let obj = parseObject(raw) else { return false }
        if obj["type"] as? String == "system",
           obj["subtype"] as? String == "compact_boundary" {
            return true
        }
        if let message = obj["message"] as? [String: Any],
           message["role"] as? String == "system",
           message["subtype"] as? String == "compact_boundary" {
            return true
        }
        return false
    }

    private static func isClearCommand(_ text: String) -> Bool {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.range(of: "<user_query>") {
            cleaned = String(cleaned[start.upperBound...])
        }
        if let end = cleaned.range(of: "</user_query>") {
            cleaned = String(cleaned[..<end.lowerBound])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned == "clear" || cleaned == "/clear" || cleaned == "/reset" || cleaned == "/new"
    }

    private static func parseObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

}
