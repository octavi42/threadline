import XCTest
@testable import threadline_overlay

final class ClaudeSourceTests: XCTestCase {
    func testSnapshotFromFixture() throws {
        let path = try fixture("claude_simple.jsonl")
        guard let snap = ClaudeSource.snapshot(forJSONL: path) else {
            XCTFail("expected a snapshot")
            return
        }
        XCTAssertEqual(snap.tool, "Claude")
        XCTAssertEqual(snap.badge, "CLD")
        XCTAssertEqual(snap.cwd, "/Users/test/proj")
        XCTAssertEqual(snap.model, "claude-opus-4-7")

        // ID is `claude:<absolute-jsonl-path>` so each tab is uniquely addressable.
        XCTAssertTrue(snap.id.hasPrefix("claude:"), "id was \(snap.id)")
        XCTAssertTrue(snap.id.hasSuffix(".jsonl"))

        // 2 TaskCreate calls → 2 tasks; the first was marked completed by a
        // later TaskUpdate, the second remains pending.
        XCTAssertEqual(snap.tasks.count, 2)
        XCTAssertEqual(snap.tasksDone, 1)
        XCTAssertEqual(snap.tasksPending, 1)
        XCTAssertEqual(snap.tasks.first?.content, "Read auth module")
        XCTAssertEqual(snap.tasks.first?.status, "completed")

        // One Edit tool_use → one file edited.
        XCTAssertEqual(snap.filesEdited, ["/Users/test/proj/auth.swift"])

        // Tool counts cover every tool_use, including the TaskCreate / TaskUpdate
        // calls themselves.
        XCTAssertEqual(snap.toolCallCounts["TaskCreate"], 2)
        XCTAssertEqual(snap.toolCallCounts["TaskUpdate"], 1)
        XCTAssertEqual(snap.toolCallCounts["Edit"],       1)

        // Last assistant text fallback (no in-progress task, no active tool target).
        XCTAssertEqual(snap.lastText, "Done with the auth read; starting on middleware.")

        // Per-tool token attribution exists for every tool that appeared in
        // the fixture (TaskCreate, TaskUpdate, Edit) and Edit's value is
        // non-zero because its tool_use input has a file_path.
        XCTAssertGreaterThan(snap.toolTokenEstimate["Edit"] ?? 0, 0)
        XCTAssertGreaterThan(snap.toolTokenEstimate["TaskCreate"] ?? 0, 0)

        // Formatter sanity checks (single source of truth in SourceSnapshot).
        XCTAssertEqual(SourceSnapshot.formatTokens(412),       "412")
        XCTAssertEqual(SourceSnapshot.formatTokens(4_234),     "4.2K")
        XCTAssertEqual(SourceSnapshot.formatTokens(120_000),   "120K")
        XCTAssertEqual(SourceSnapshot.formatTokens(1_200_000), "1.2M")
    }
}

final class CodexSourceTests: XCTestCase {
    func testSnapshotFromFixture() throws {
        let path = try fixture("codex_simple.jsonl")
        guard let snap = CodexSource.snapshot(forJSONL: path) else {
            XCTFail("expected a snapshot")
            return
        }
        XCTAssertEqual(snap.tool, "Codex")
        XCTAssertEqual(snap.badge, "CDX")
        XCTAssertEqual(snap.cwd, "/Users/test/proj")
        XCTAssertEqual(snap.model, "gpt-5")
        XCTAssertTrue(snap.id.hasPrefix("codex:"), "id was \(snap.id)")

        // token_count: 1500 input + 800 cached = 2300 / 256000 ≈ 0.9%
        XCTAssertNotNil(snap.contextPercent)
        if let pct = snap.contextPercent {
            XCTAssertEqual(pct, 2300.0 / 256000.0, accuracy: 0.001)
        }

        XCTAssertEqual(snap.lastText, "On it — adding /auth/logout to the router.")
    }
}

// MARK: - helpers

private func fixture(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
        throw NSError(domain: "fixture-missing", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "fixture \(name) not found"])
    }
    return url.path
}
