import XCTest
@testable import threadline_overlay

/// Scans real Claude/Codex sessions on this Mac. Set THREADLINE_LIVE_TEST=1 to run.
final class LiveConsistencyTests: XCTestCase {
    func testInboxAndDetailShareSameWorkState() throws {
        try requireLiveTest()
        var all: [SourceSnapshot] = []

        for session in LiveAgents.liveSessions() {
            var snap: SourceSnapshot?
            switch session.tool {
            case "Claude": snap = ClaudeSource.snapshot(forJSONL: session.jsonlPath)
            case "Codex":  snap = CodexSource.snapshot(forJSONL: session.jsonlPath)
            case "Cursor": snap = CursorAgentSource.snapshot(forJSONL: session.jsonlPath)
            default:       continue
            }
            guard var s = snap else { continue }
            s.livePid = session.pid
            all.append(SourceSnapshot.withDerivedFields(s))
        }

        try XCTSkipIf(all.isEmpty, "No live agent sessions on this machine")

        var mismatches: [String] = []
        var unstable: [String] = []

        for snap in all {
            let a = snap.workState
            let b = WorkStatusResolver.resolveStable(snap)
            let c = WorkStatusResolver.resolveStable(snap)

            if a != b {
                mismatches.append("\(snap.tool) \(snap.id): derived=\(a.status) stable=\(b.status)")
            }
            if b != c {
                unstable.append("\(snap.tool) \(snap.id): \(b.status) -> \(c.status)")
            }
        }

        XCTAssertTrue(mismatches.isEmpty, "withDerivedFields vs resolveStable:\n" + mismatches.joined(separator: "\n"))
        XCTAssertTrue(unstable.isEmpty, "resolveStable flicker:\n" + unstable.joined(separator: "\n"))
    }

    private func requireLiveTest() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["THREADLINE_LIVE_TEST"] != "1",
                      "Set THREADLINE_LIVE_TEST=1 to scan local agent logs")
    }

    func testBuilderIncludesCursorSessions() throws {
        try requireLiveTest()
        let all = SessionSnapshotBuilder.buildSnapshots(includeCursorHistory: true)
        let cursor = all.filter { $0.tool == "Cursor" }
        print("BUILDER_CURSOR_COUNT \(cursor.count) TOTAL \(all.count)")
        XCTAssertGreaterThan(cursor.count, 0, "expected Cursor agent sessions from ~/.cursor/projects")
    }

    func testLiveOnlyCursorInboxMatchesRunningAgents() throws {
        try requireLiveTest()
        let liveCount = LiveAgents.liveSessions().filter { $0.tool == "Cursor" }.count
        let built = SessionSnapshotBuilder.build(includeCursorHistory: false)
        let inboxCursor = built.snapshots.filter { $0.tool == "Cursor" }
        print("LIVE_CURSOR_AGENTS \(liveCount) INBOX_CURSOR \(inboxCursor.count) HIDDEN_HISTORY \(built.hiddenCursorHistoryCount)")
        XCTAssertEqual(inboxCursor.count, liveCount)
        for snap in inboxCursor {
            XCTAssertNotNil(snap.livePid, "inbox Cursor rows should be live")
        }
        if liveCount > 0 {
            XCTAssertGreaterThan(built.hiddenCursorHistoryCount, 0,
                                 "disk history should be hidden when live agents exist")
        }
    }

    func testStatusDistributionSnapshot() throws {
        try requireLiveTest()
        var all: [SourceSnapshot] = []
        for session in LiveAgents.liveSessions() {
            var snap: SourceSnapshot?
            switch session.tool {
            case "Claude": snap = ClaudeSource.snapshot(forJSONL: session.jsonlPath)
            case "Codex":  snap = CodexSource.snapshot(forJSONL: session.jsonlPath)
            case "Cursor": snap = CursorAgentSource.snapshot(forJSONL: session.jsonlPath)
            default:       continue
            }
            guard var s = snap else { continue }
            s.livePid = session.pid
            all.append(SourceSnapshot.withDerivedFields(s))
        }
        try XCTSkipIf(all.isEmpty, "No live sessions")

        var counts: [WorkStatus: Int] = [:]
        for snap in all {
            counts[snap.workState.status, default: 0] += 1
        }
        let summary = counts.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.rawValue): \(counts[$0]!)" }
            .joined(separator: ", ")
        print("LIVE_STATUS_DISTRIBUTION \(all.count) sessions — \(summary)")

        let inboxVisible = all.filter {
            WorkStatusResolver.isVisibleInInbox($0, showInactive: false, showOlder: false)
        }
        print("LIVE_INBOX_DEFAULT \(inboxVisible.count) visible (24h window, no done)")
    }
}
