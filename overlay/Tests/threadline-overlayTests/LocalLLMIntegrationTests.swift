import XCTest
@testable import threadline_overlay

/// Live Ollama tests — run with:
///   THREADLINE_OLLAMA_INTEGRATION=1 THREADLINE_OLLAMA_MODEL=qwen2.5vl:7b swift test --filter LocalLLMIntegration
final class LocalLLMIntegrationTests: XCTestCase {
    override func setUp() {
        guard ProcessInfo.processInfo.environment["THREADLINE_OLLAMA_INTEGRATION"] == "1" else {
            return
        }
        if let model = ProcessInfo.processInfo.environment["THREADLINE_OLLAMA_MODEL"] {
            setenv("THREADLINE_OLLAMA_MODEL", model, 1)
        }
    }

    func testLiveSummary() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADLINE_OLLAMA_INTEGRATION"] == "1",
            "Set THREADLINE_OLLAMA_INTEGRATION=1 and run Ollama"
        )
        let text = LocalLLM.complete(
            system: "Return one short present-tense line. Maximum 12 words. No preamble.",
            user: "user: refactor auth middleware\nassistant: editing auth.swift",
            maxTokens: 60,
            timeout: 90
        )
        XCTAssertNotNil(text)
        XCTAssertFalse(text!.isEmpty)
        XCTAssertLessThanOrEqual(text!.split(separator: " ").count, 20)
    }

    func testLiveClassifyJSON() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADLINE_OLLAMA_INTEGRATION"] == "1",
            "Set THREADLINE_OLLAMA_INTEGRATION=1 and run Ollama"
        )
        let system = """
        Return only one JSON object with keys status, reason, nextAction. \
        status must be one of: Needs you, Tests failed, Stuck, Risky, Ready, Working, Done.
        """
        let evidence = """
        project: threadline
        branch: main
        files_edited: auth.swift
        recent_turns:
        user: please run /login
        """
        let raw = LocalLLM.complete(system: system, user: evidence, maxTokens: 120, timeout: 90)
        XCTAssertNotNil(raw)
        let lower = raw!.lowercased()
        XCTAssertTrue(lower.contains("needs you") || lower.contains("needs_you"),
                      "expected Needs you classification, got: \(raw!)")
    }

    func testSummarizerEndToEnd() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADLINE_OLLAMA_INTEGRATION"] == "1",
            "Set THREADLINE_OLLAMA_INTEGRATION=1 and run Ollama"
        )
        let source = try integrationFixture("claude_simple.jsonl")
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("threadline-ollama-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(atPath: source, toPath: tmp)
        let mtime = Date()
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: tmp)

        let exp = expectation(description: "summarizer")
        var summary: String?
        _ = Summarizer.shared.summary(forJSONL: tmp, mtime: mtime) { text in
            summary = text
            exp.fulfill()
        }
        wait(for: [exp], timeout: 120)
        try? FileManager.default.removeItem(atPath: tmp)
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary!.isEmpty)
    }
}

private func integrationFixture(_ name: String) throws -> String {
    if let url = Bundle.module.url(forResource: name, withExtension: nil) {
        return url.path
    }
    let dir = (#file as NSString).deletingLastPathComponent
    let path = (dir as NSString).appendingPathComponent("Fixtures/\(name)")
    guard FileManager.default.fileExists(atPath: path) else {
        throw NSError(domain: "test", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
    }
    return path
}
