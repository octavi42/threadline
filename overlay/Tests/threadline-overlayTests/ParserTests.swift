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

        // One Edit + one Write → two files edited.
        XCTAssertEqual(snap.filesEdited, ["/Users/test/proj/auth.swift",
                                          "/Users/test/proj/middleware.swift"])

        // Tool counts cover every tool_use, including the TaskCreate / TaskUpdate
        // calls themselves.
        XCTAssertEqual(snap.toolCallCounts["TaskCreate"], 2)
        XCTAssertEqual(snap.toolCallCounts["TaskUpdate"], 1)
        XCTAssertEqual(snap.toolCallCounts["Edit"],       1)
        XCTAssertEqual(snap.toolCallCounts["Write"],      1)

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

        // Edit's old_string had 3 lines, new_string had 5 lines.
        // Write's content has 3 lines (trailing newline counts).
        XCTAssertEqual(snap.linesRemoved, 3)
        XCTAssertEqual(snap.linesAdded,   8)

        // --- fileChanges: per-file edit operations ---
        XCTAssertEqual(snap.fileChanges.count, 2)

        let authGroup = snap.fileChanges.first { $0.path == "/Users/test/proj/auth.swift" }
        XCTAssertNotNil(authGroup)
        XCTAssertEqual(authGroup?.edits.count, 1)
        XCTAssertEqual(authGroup?.edits.first?.tool, "Edit")
        XCTAssertEqual(authGroup?.edits.first?.oldText, "line1\nline2\nline3")
        XCTAssertEqual(authGroup?.edits.first?.newText, "new1\nnew2\nnew3\nnew4\nnew5")
        XCTAssertEqual(authGroup?.linesAdded, 5)
        XCTAssertEqual(authGroup?.linesRemoved, 3)

        let mwGroup = snap.fileChanges.first { $0.path == "/Users/test/proj/middleware.swift" }
        XCTAssertNotNil(mwGroup)
        XCTAssertEqual(mwGroup?.edits.count, 1)
        XCTAssertEqual(mwGroup?.edits.first?.tool, "Write")
        XCTAssertEqual(mwGroup?.edits.first?.note, "full file write")
        XCTAssertEqual(mwGroup?.linesAdded, 3)
        XCTAssertEqual(mwGroup?.linesRemoved, 0)

        // Unique IDs across all edit ops.
        let allIDs = snap.fileChanges.flatMap(\.edits).map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count, "edit op IDs must be unique")
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
        XCTAssertEqual(snap.filesEdited, ["/Users/test/proj/auth.swift",
                                          "/Users/test/proj/router.swift"])
        XCTAssertEqual(snap.toolCallCounts["apply_patch"], 1)
        XCTAssertEqual(snap.linesAdded, 2)
        XCTAssertEqual(snap.linesRemoved, 1)

        let routerGroup = snap.fileChanges.first { $0.path == "/Users/test/proj/router.swift" }
        XCTAssertEqual(routerGroup?.edits.first?.tool, "apply_patch")
        XCTAssertTrue(routerGroup?.edits.first?.patchText.contains("/auth/logout") == true)
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
