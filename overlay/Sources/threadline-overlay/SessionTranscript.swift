import Foundation

/// Normalized human-readable transcript extracted from a Claude or Codex JSONL.
/// This is the shared ingestion layer for consumers that need evidence text
/// without each reparsing provider-specific record shapes.
struct SessionTranscript: Equatable {
    struct Snippet: Equatable {
        let role: String
        let text: String
    }

    var snippets: [Snippet] = []
    var toolLines: [String] = []
    var relevantOutputs: [String] = []

    var evidenceText: String? {
        let lines = snippets.map(\.text) + relevantOutputs
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    var summaryText: String? {
        let lines = snippets.map { snippet in
            snippet.role.isEmpty ? snippet.text : "\(snippet.role): \(snippet.text)"
        } + toolLines.map { "tool: \($0)" }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n\n")
    }

    var openingGoal: String? {
        for snippet in snippets where snippet.role == "user" {
            if let goal = Self.substantiveUserText(snippet.text) {
                return goal
            }
        }
        return nil
    }

    static func shouldDiscardSnippet(_ text: String) -> Bool {
        let lower = text.lowercased()
        let noise = [
            "summarize this coding-assistant session",
            "summarize this claude code session transcript",
            "summarise this session",
            "return one short present-tense line",
            "maximum 12 words",
            "classify the session from stdin",
            "uses your installed `claude -p`",
            "x-ray analysis",
        ]
        if noise.contains(where: { lower.contains($0) }) { return true }
        if lower.hasPrefix("i've made the current session") { return true }
        if lower.hasPrefix("i've made the following changes") { return true }
        if lower.hasPrefix("the current state of the project") { return true }
        if lower.hasPrefix("the project's current focus is on") { return true }
        return false
    }

    static func substantiveUserText(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 12, !shouldDiscardSnippet(cleaned) else { return nil }
        let lower = cleaned.lowercased()
        if lower == "yes" || lower == "continue" || lower == "go ahead" { return nil }
        return cleaned
    }
}

enum SessionTranscriptCache {
    private struct CacheKey: Hashable {
        let path: String
        let mtime: Date
        let maxBytes: Int?
    }

    private static let lock = NSLock()
    private static var memory: [CacheKey: SessionTranscript] = [:]

    static func transcript(fromJSONL path: String, maxBytes: Int? = nil) -> SessionTranscript? {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
            ?? .distantPast
        let key = CacheKey(path: path, mtime: mtime, maxBytes: maxBytes)

        lock.lock()
        if let hit = memory[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let text: String?
        if let maxBytes = maxBytes {
            text = tailOfFile(path: path, maxBytes: maxBytes)
        } else {
            text = try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard let text = text else { return nil }

        let parsed = parse(text)
        lock.lock()
        memory[key] = parsed
        if memory.count > 64 {
            let staleKeys = memory.keys
                .sorted { $0.mtime < $1.mtime }
                .prefix(memory.count - 48)
            staleKeys.forEach { memory.removeValue(forKey: $0) }
        }
        lock.unlock()
        return parsed
    }

    private static func parse(_ text: String) -> SessionTranscript {
        var out = SessionTranscript()

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let message = obj["message"] as? [String: Any] {
                appendClaudeMessage(message, into: &out)
                continue
            }

            let type = obj["type"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if type == "event_msg" {
                appendCodexEvent(payload, into: &out)
            } else if type == "response_item" {
                appendCodexResponseItem(payload, into: &out)
            }
        }

        return out
    }

    private static func appendClaudeMessage(_ message: [String: Any],
                                            into out: inout SessionTranscript) {
        let role = message["role"] as? String ?? ""
        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String,
                       keepSnippet(t) {
                        out.snippets.append(SessionTranscript.Snippet(role: role, text: t))
                    }
                case "tool_use":
                    if let line = toolUseLine(block) {
                        out.toolLines.append(line)
                    }
                case "tool_result":
                    if let body = extractToolResultText(block["content"]),
                       outputIsRelevant(body) {
                        out.relevantOutputs.append(body)
                    }
                default:
                    break
                }
            }
        } else if let s = message["content"] as? String, keepSnippet(s) {
            out.snippets.append(SessionTranscript.Snippet(role: role, text: s))
        }
    }

    private static func appendCodexEvent(_ payload: [String: Any],
                                         into out: inout SessionTranscript) {
        switch payload["type"] as? String {
        case "agent_message", "user_message":
            guard let msg = payload["message"] as? String, keepSnippet(msg) else { return }
            let role = payload["type"] as? String == "user_message" ? "user" : "assistant"
            out.snippets.append(SessionTranscript.Snippet(role: role, text: msg))
        case "patch_apply_end":
            if let changes = payload["changes"] as? [String: Any] {
                for path in changes.keys.sorted() {
                    out.toolLines.append("apply_patch \((path as NSString).lastPathComponent)")
                }
            }
        default:
            break
        }
    }

    private static func appendCodexResponseItem(_ payload: [String: Any],
                                                into out: inout SessionTranscript) {
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String ?? ""
            let content = payload["content"] as? [[String: Any]] ?? []
            for block in content {
                for key in ["text", "input_text", "output_text"] {
                    if let t = block[key] as? String, keepSnippet(t) {
                        out.snippets.append(SessionTranscript.Snippet(role: role, text: t))
                    }
                }
            }
        case "custom_tool_call":
            if let line = codexToolLine(payload) {
                out.toolLines.append(line)
            }
        case "function_call_output":
            if let output = payload["output"] as? String,
               outputIsRelevant(output) {
                out.relevantOutputs.append(output)
            }
        default:
            break
        }
    }

    private static func keepSnippet(_ text: String) -> Bool {
        !text.isEmpty
            && !text.hasPrefix("<")
            && !SessionTranscript.shouldDiscardSnippet(text)
    }

    private static func outputIsRelevant(_ output: String) -> Bool {
        let lower = output.lowercased()
        let needles = [
            "swift test", "pytest", "npm test", "yarn test", "cargo test",
            "vitest", "jest", "go test", "exit code", "exit status",
            "tests pass", "test pass", "tests failed", "test failed",
            "0 failures", "conclusion", "github action", "workflow run",
        ]
        return needles.contains { lower.contains($0) }
    }

    private static func toolUseLine(_ block: [String: Any]) -> String? {
        guard let name = block["name"] as? String else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        if let path = input["file_path"] as? String {
            return "\(name) \((path as NSString).lastPathComponent)"
        }
        if let cmd = input["command"] as? String {
            let first = cmd.split(separator: "\n").first.map(String.init) ?? cmd
            return "\(name) \(SourceSnapshot.compactLine(first, limit: 120, firstSentence: false))"
        }
        if let pattern = input["pattern"] as? String {
            return "\(name) \(SourceSnapshot.compactLine(pattern, limit: 80, firstSentence: false))"
        }
        if let query = input["query"] as? String {
            return "\(name) \(SourceSnapshot.compactLine(query, limit: 80, firstSentence: false))"
        }
        return name
    }

    private static func codexToolLine(_ payload: [String: Any]) -> String? {
        guard let name = payload["name"] as? String, !name.isEmpty else { return nil }
        if let rawInput = payload["input"] as? String {
            if name == "apply_patch" {
                let paths = parsePatchPaths(rawInput)
                if let first = paths.first {
                    return "\(name) \((first as NSString).lastPathComponent)"
                }
            }
            return "\(name) \(SourceSnapshot.compactLine(rawInput, limit: 120, firstSentence: false))"
        }
        return name
    }

    private static func parsePatchPaths(_ patch: String) -> [String] {
        var paths: Set<String> = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if s.hasPrefix("*** Update File: ") {
                paths.insert(String(s.dropFirst("*** Update File: ".count)))
            } else if s.hasPrefix("*** Add File: ") {
                paths.insert(String(s.dropFirst("*** Add File: ".count)))
            } else if s.hasPrefix("*** Delete File: ") {
                paths.insert(String(s.dropFirst("*** Delete File: ".count)))
            } else if s.hasPrefix("+++ b/") {
                paths.insert(String(s.dropFirst(6)))
            } else if s.hasPrefix("--- a/") {
                paths.insert(String(s.dropFirst(6)))
            }
        }
        return paths.sorted()
    }

    private static func extractToolResultText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return nil }
        let parts = arr.compactMap { $0["text"] as? String }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}
