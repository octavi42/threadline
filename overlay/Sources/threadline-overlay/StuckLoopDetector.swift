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
        analyze(blocks: errorBlocks(fromJSONL: jsonlPath, maxBytes: maxBytes))
    }

    static func analyze(text: String) -> Result? {
        let snippets = uniqueErrorSnippets(in: text)
        return analyze(snippets: snippets)
    }

    static func analyze(blocks: [String]) -> Result? {
        let snippets = blocks
            .filter { !isSuccessfulCodexToolOutput($0) }
            .flatMap(uniqueErrorSnippets)
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

    private static func uniqueErrorSnippets(in text: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            guard isErrorSnippet(s) else { continue }
            let fp = fingerprint(s)
            guard !fp.isEmpty, !seen.contains(fp) else { continue }
            seen.insert(fp)
            out.append(s)
        }
        if out.isEmpty, isErrorSnippet(text) {
            out.append(text)
        }
        return out
    }

    // MARK: - JSONL extraction

    private static func errorBlocks(fromJSONL path: String, maxBytes: Int) -> [String] {
        guard let tail = tailOfFile(path: path, maxBytes: maxBytes) else { return [] }
        var blocks: [String] = []

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let message = obj["message"] as? [String: Any] {
                appendClaudeErrors(message, into: &blocks)
                continue
            }

            let type = obj["type"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if type == "response_item", payload["type"] as? String == "function_call_output",
               let output = payload["output"] as? String {
                if isSuccessfulCodexToolOutput(output) { continue }
                appendErrorBlock(output, into: &blocks)
            }
        }

        return blocks
    }

    private static func appendClaudeErrors(_ message: [String: Any], into blocks: inout [String]) {
        guard let content = message["content"] as? [[String: Any]] else { return }
        for block in content {
            guard block["type"] as? String == "tool_result",
                  let text = block["content"] as? String
            else { continue }
            appendErrorBlock(text, into: &blocks)
        }
    }

    private static func appendErrorBlock(_ text: String, into blocks: inout [String]) {
        if !uniqueErrorSnippets(in: text).isEmpty {
            blocks.append(text)
        }
    }

    private static func isSuccessfulCodexToolOutput(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("process exited with code 0")
            || lower.contains("exit code: 0")
            || lower.contains("exit status: 0")
    }

    // MARK: - heuristics

    private static func isErrorSnippet(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        let lower = trimmed.lowercased()

        if lower.contains("no error") || lower.contains("without error") { return false }
        if lower.hasPrefix("reduced false stuck") { return false }
        if lower.contains("same error repeated") { return false }
        if lower.contains("status of stuck") { return false }
        if lower.contains("status: stuck") { return false }
        if lower.contains("stuckloopdetector") { return false }
        if lower.contains("requestsdependencywarning") { return false }
        if lower.contains("process exited with code 0") { return false }
        if lower.contains("exit code: 0") || lower.contains("exit status: 0") { return false }
        if lower.contains("0 failures") || lower.contains("with 0 failures") { return false }

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
