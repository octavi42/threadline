import Foundation

/// Detects when an agent retries the same failing command/error in a session tail.
enum StuckLoopDetector {
    /// Inclusive repeat count that marks a session as stuck (e.g. 3 = third identical error).
    static let minimumRepeats = 3

    struct Result: Equatable {
        let repeatCount: Int
        let fingerprint: String
    }

    static func analyze(jsonlPath: String, maxBytes: Int = 96 * 1024) -> Result? {
        analyze(snippets: errorSnippets(fromJSONL: jsonlPath, maxBytes: maxBytes))
    }

    static func analyze(text: String) -> Result? {
        let snippets = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter(isErrorSnippet)
        return analyze(snippets: snippets)
    }

    static func reason(for result: Result) -> String {
        "same error repeated \(result.repeatCount)×"
    }

    // MARK: - core

    private static func analyze(snippets: [String]) -> Result? {
        var counts: [String: Int] = [:]
        for snippet in snippets {
            let fp = fingerprint(snippet)
            guard !fp.isEmpty else { continue }
            counts[fp, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value }),
              best.value >= minimumRepeats
        else { return nil }
        return Result(repeatCount: best.value, fingerprint: best.key)
    }

    // MARK: - JSONL extraction

    private static func errorSnippets(fromJSONL path: String, maxBytes: Int) -> [String] {
        guard let tail = tailOfFile(path: path, maxBytes: maxBytes) else { return [] }
        var snippets: [String] = []

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let message = obj["message"] as? [String: Any] {
                appendClaudeErrors(message, into: &snippets)
                continue
            }

            let type = obj["type"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if type == "response_item", payload["type"] as? String == "function_call_output",
               let output = payload["output"] as? String {
                appendErrorBlock(output, into: &snippets)
            }
        }

        return snippets
    }

    private static func appendClaudeErrors(_ message: [String: Any], into snippets: inout [String]) {
        guard let content = message["content"] as? [[String: Any]] else { return }
        for block in content {
            guard block["type"] as? String == "tool_result",
                  let text = block["content"] as? String
            else { continue }
            appendErrorBlock(text, into: &snippets)
        }
    }

    private static func appendErrorBlock(_ text: String, into snippets: inout [String]) {
        let before = snippets.count
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if isErrorSnippet(s) { snippets.append(s) }
        }
        if snippets.count == before && isErrorSnippet(text) {
            snippets.append(text)
        }
    }

    // MARK: - heuristics

    private static func isErrorSnippet(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        let lower = trimmed.lowercased()

        if lower.contains("no error") || lower.contains("without error") { return false }
        if lower.hasPrefix("reduced false stuck") { return false }

        let needles = [
            "error:", "error ", " failed", "failed:", "failure",
            "exit code", "exit status", "exited with",
            "panic:", "exception", "traceback",
            "cannot ", "can't ", "could not",
            "enoent", "eacces", "econnrefused",
            "undefined", "not found", "not defined",
            "compilation failed", "build failed", "command not found",
            "syntax error", "type error", "fatal error",
            "assertion failed", "test failed", "tests failed",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Normalize an error line so path/timestamp drift still matches across retries.
    static func fingerprint(_ line: String) -> String {
        var s = line.lowercased()
        s = s.replacingOccurrences(
            of: #"\d{4}-\d{2}-\d{2}[tT ]\d{2}:\d{2}:\d{2}[^ \n]*"#,
            with: "<ts>",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"/[\w./~-]+"#,
            with: "<path>",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\b0x[0-9a-f]+\b"#,
            with: "<addr>",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #":\d{1,5}:\d{1,5}\b"#,
            with: ":<line>:<col>",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\b\d+\b"#,
            with: "<n>",
            options: .regularExpression
        )
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 180 {
            s = String(s.prefix(179)) + "…"
        }
        return s
    }
}
