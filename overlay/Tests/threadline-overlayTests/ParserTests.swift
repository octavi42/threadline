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

final class WorkStatusResolverTests: XCTestCase {
    func testNeedsYouBeatsCodeRiskWhenBlocked() {
        var snap = baseSnapshot(state: .idle)
        snap.filesEdited = ["/tmp/Auth.swift"]
        snap.lastText = "You're out of extra usage · resets later."

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .needsYou)
        XCTAssertEqual(work.reason, "usage limit reached")
        XCTAssertEqual(work.nextAction, "Jump back")
    }

    func testRiskyWhenCodeChangedWithoutEvidence() {
        var snap = baseSnapshot(state: .idle)
        snap.filesEdited = ["/tmp/Auth.swift", "/tmp/Router.swift"]

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .risky)
        XCTAssertEqual(work.reason, "2 files changed - no test evidence")
        XCTAssertEqual(work.nextAction, "Run tests")
    }

    func testReadyWhenCodeChangedAndTestsPassed() {
        var snap = baseSnapshot(state: .idle)
        snap.filesEdited = ["/tmp/Auth.swift"]
        snap.lastText = "swift test passed"

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .ready)
        XCTAssertEqual(work.reason, "1 file changed - tests passed")
        XCTAssertEqual(work.nextAction, "Review diff")
    }

    func testResearchOnlyDoneIsNotRisky() {
        var snap = baseSnapshot(state: .idle)
        snap.lastText = "Here is the research summary."

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .done)
        XCTAssertEqual(work.reason, "answer complete")
    }

    func testHelperSummariesAreHidden() {
        var snap = baseSnapshot(state: .running)
        snap.lastText = "Summarize this coding-assistant session in 2-3 short sentences."

        XCTAssertFalse(WorkStatusResolver.shouldDisplay(snap))
    }

    func testSortsAttentionBeforeRecency() {
        var ready = baseSnapshot(state: .idle, id: "ready")
        ready.filesEdited = ["/tmp/A.swift"]
        ready.lastText = "swift test passed"
        ready.updatedAt = Date()

        var needs = baseSnapshot(state: .idle, id: "needs")
        needs.lastText = "Please run /login."
        needs.updatedAt = Date().addingTimeInterval(-3600)

        let readySnap = SourceSnapshot.withDerivedFields(ready)
        let needsSnap = SourceSnapshot.withDerivedFields(needs)
        XCTAssertTrue(WorkStatusResolver.sort(needsSnap, readySnap))
    }

    func testOldLivePidIsNotWorkingByItself() {
        var snap = baseSnapshot(state: .idle)
        snap.livePid = 123
        snap.updatedAt = Date().addingTimeInterval(-3600)

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .done)
    }

    func testStatusWordsAloneDoNotCreateFailedTests() {
        var snap = baseSnapshot(state: .idle)
        snap.lastText = "We discussed labels like Tests failed and Risky."

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .done)
    }

    func testExitCode10IsNotFailedTests() {
        var snap = baseSnapshot(state: .idle)
        snap.lastText = "Process finished with exit code 10."

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertNotEqual(work.status, .testsFailed)
    }

    func testExitCode1IsFailedTests() {
        var snap = baseSnapshot(state: .idle)
        snap.lastText = "Command failed with exit code: 1"

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .testsFailed)
    }

    func testChangelogMentionOfRepeatedEditsIsNotStuck() {
        var snap = baseSnapshot(state: .stale)
        snap.lastText = """
        Reduced false Stuck: repeated edits to the same file no longer automatically mean stuck.
        """

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertNotEqual(work.status, .stuck)
    }

    func testStaleWithInProgressTasksIsStuck() {
        var snap = baseSnapshot(state: .stale)
        snap.tasks = [
            TaskItem(content: "Finish auth refactor", status: "in_progress"),
            TaskItem(content: "Run tests", status: "pending"),
        ]
        snap.tasksInProgress = 1

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .stuck)
        XCTAssertEqual(work.reason, "stale with work in progress")
    }

    func testAllSwiftTestsPassInTranscriptTailIsReady() throws {
        let path = try fixture("codex_tests_passed.jsonl")
        var snap = baseSnapshot(state: .idle)
        snap.jsonlPath = path
        snap.filesEdited = ["/tmp/A.swift", "/tmp/B.swift"]
        snap.lastText = "Implemented and restarted the app."

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .ready)
        XCTAssertEqual(work.reason, "2 files changed - tests passed")
    }

    func testZombieLiveSessionWithChangesIsDoneNotRisky() {
        var snap = baseSnapshot(state: .idle)
        snap.livePid = 99
        snap.updatedAt = Date().addingTimeInterval(-3 * 3600)
        snap.filesEdited = ["/tmp/old.swift"]

        let work = WorkStatusResolver.resolve(snap)

        XCTAssertEqual(work.status, .done)
        XCTAssertEqual(work.reason, "old session · unverified changes")
    }

    func testActivityLineCompactsLongAssistantText() {
        var snap = baseSnapshot(state: .idle)
        snap.lastText = """
        I inspected the current implementation and found the issue.
        The fix should focus on the focused terminal identity path instead of the folder fallback.
        """

        XCTAssertEqual(snap.activityLine,
                       "I inspected the current implementation and found the issue.")
    }

    func testActivityLineTruncatesVeryLongText() {
        let text = "Threadline is rebuilding the session inbox around concise current activity summaries for active agents"

        XCTAssertEqual(SourceSnapshot.compactLine(text, limit: 48),
                       "Threadline is rebuilding the session inbox...")
    }

    func testNormalizeSummaryCapsWordCount() {
        let text = """
        Threadline is rebuilding the session inbox around concise current activity summaries
        for active agents so nobody reads long transcript style messages anymore
        """

        let normalized = SourceSnapshot.normalizeSummary(text)
        let words = normalized.split(separator: " ", omittingEmptySubsequences: true)

        XCTAssertLessThanOrEqual(words.count, 13) // 12 words + optional "..."
        XCTAssertTrue(normalized.hasSuffix("..."))
    }

    func testNormalizeSummaryIsIdempotent() {
        let raw = "Fixing overlay summary compaction and normalizing cached session text"
        let once = SourceSnapshot.normalizeSummary(raw)
        XCTAssertEqual(SourceSnapshot.normalizeSummary(once), once)
    }

    private func baseSnapshot(state: SourceState, id: String = "snap") -> SourceSnapshot {
        var snap = SourceSnapshot(id: id, tool: "Codex", badge: "CDX")
        snap.cwd = "/tmp/project"
        snap.state = state
        snap.updatedAt = Date()
        return snap
    }
}

final class FolderTrustSummaryTests: XCTestCase {
    func testRollupLineOrdersByUrgency() {
        let folder = SessionFolder(
            cwd: "/tmp/project",
            snapshots: [
                snap(id: "a", status: .ready),
                snap(id: "b", status: .risky),
                snap(id: "c", status: .needsYou),
            ]
        )
        let summary = folder.trustSummary(workStates: [:])
        XCTAssertEqual(summary.rollupLine, "1 Needs you · 1 Risky · 1 Ready")
        XCTAssertEqual(summary.attentionCount, 3)
    }

    func testVisibleSnapshotsHidesDoneByDefault() {
        let folder = SessionFolder(
            cwd: "/tmp/project",
            snapshots: [
                snap(id: "a", status: .ready),
                snap(id: "b", status: .done),
            ]
        )
        let visible = folder.visibleSnapshots(showInactive: false, workStates: [:])
        XCTAssertEqual(visible.map(\.id), ["a"])
        let all = folder.visibleSnapshots(showInactive: true, workStates: [:])
        XCTAssertEqual(all.count, 2)
    }

    private func snap(id: String, status: WorkStatus) -> SourceSnapshot {
        var s = SourceSnapshot(id: id, tool: "Claude", badge: "CLD")
        s.workState = WorkState(status: status, reason: "", nextAction: "", rank: 0)
        return s
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
