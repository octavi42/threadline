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
        let all = SessionSnapshotBuilder.buildSnapshots()
        let cursor = all.filter { $0.tool == "Cursor" }
        print("BUILDER_CURSOR_COUNT \(cursor.count) TOTAL \(all.count)")
        XCTAssertGreaterThan(cursor.count, 0, "expected Cursor agent sessions from ~/.cursor/projects")
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
