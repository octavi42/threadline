import XCTest
@testable import threadline_overlay

final class SessionGrouperTests: XCTestCase {
    func testCodexClearKeepsOnlyNewestOpenRolloutLive() {
        let prior = "/Users/test/.codex/sessions/2026/05/25/rollout-prior.jsonl"
        let current = "/Users/test/.codex/sessions/2026/05/25/rollout-current.jsonl"
        let dates = [
            prior: Date(timeIntervalSince1970: 100),
            current: Date(timeIntervalSince1970: 200),
        ]

        let selected = LiveAgents.preferredCodexJSONLPath(
            from: [prior, current, prior],
            createdAt: { dates[$0] }
        )

        XCTAssertEqual(selected, current)
    }

    func testHotRefreshReconcilesReplacementForSameLiveProcess() {
        var prior = makeSnapshot(id: "prior", cwd: "/proj")
        prior.livePid = 99
        var current = makeSnapshot(id: "current", cwd: "/proj")
        current.livePid = 99

        XCTAssertTrue(SessionModel.containsLiveSessionReplacement(
            updates: [current],
            existing: [prior]
        ))
        XCTAssertFalse(SessionModel.containsLiveSessionReplacement(
            updates: [prior],
            existing: [prior]
        ))
    }

    func testMergeInboxRowsPreservesOrder() {
        let current: [InboxRow] = [
            .folderHeader(cwd: "/a"),
            .agent(snapshotID: "s1", folderCWD: "/a", isFirst: true, isLast: false),
            .agent(snapshotID: "s2", folderCWD: "/a", isFirst: false, isLast: true),
            .folderHeader(cwd: "/b"),
            .agent(snapshotID: "s3", folderCWD: "/b", isFirst: true, isLast: true),
        ]
        let desired: [InboxRow] = [
            .folderHeader(cwd: "/b"),
            .agent(snapshotID: "s3", folderCWD: "/b", isFirst: true, isLast: true),
            .folderHeader(cwd: "/a"),
            .agent(snapshotID: "s1", folderCWD: "/a", isFirst: true, isLast: false),
            .agent(snapshotID: "s2", folderCWD: "/a", isFirst: false, isLast: true),
            .folderHeader(cwd: "/c"),
            .agent(snapshotID: "s4", folderCWD: "/c", isFirst: true, isLast: true),
        ]

        let merged = SessionGrouper.mergeInboxRows(current: current, desired: desired)
        XCTAssertEqual(merged.map(\.id), [
            "folder:/a", "s1", "s2", "folder:/b", "s3", "folder:/c", "s4",
        ])
    }

    func testMakeStableFoldersUsesStableOrder() {
        let s1 = makeSnapshot(id: "s1", cwd: "/proj")
        let s2 = makeSnapshot(id: "s2", cwd: "/proj")
        let byID = [s1.id: s1, s2.id: s2]
        let folders = SessionGrouper.makeStableFolders(from: byID,
                                                       folderOrder: ["/proj"],
                                                       agentOrderByFolder: ["/proj": ["s2", "s1"]])
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].snapshots.map(\.id), ["s2", "s1"])
    }

    func testSnapshotCellApplySkipsIdentical() {
        let snap = makeSnapshot(id: "s1", cwd: "/proj")
        let cell = SnapshotCell(snapshot: snap)
        cell.apply(snap)
        XCTAssertEqual(cell.snapshot.id, "s1")
    }

    func testResolveLiveUpgradesActiveAgentToWorking() {
        var snap = makeSnapshot(id: "s1", cwd: "/proj")
        snap.livePid = 99999
        snap.updatedAt = Date()
        snap.state = .running
        snap.filesEdited = ["src/main.swift"]
        snap = SourceSnapshot.withDerivedFields(snap)
        let live = WorkStatusResolver.resolveLive(snap)
        XCTAssertEqual(live.status, .working)
    }

    func testSessionStateRestoreDropsTransientLiveIdentity() {
        let record = SessionStateStore.Record(id: "s1",
                                              tool: "Codex",
                                              cwd: "/proj",
                                              jsonlPath: "/tmp/session.jsonl",
                                              status: .working,
                                              state: .running,
                                              pid: 99999,
                                              updatedAt: Date(),
                                              lastText: "agent is active")

        let restored = SessionStateStore.snapshot(from: record)

        XCTAssertNil(restored.livePid)
        XCTAssertEqual(restored.state, .idle)
        XCTAssertEqual(restored.workState.status, .done)
    }

    func testSessionStateSaveDoesNotPersistLivePID() {
        var snap = makeSnapshot(id: "s1", cwd: "/proj")
        snap.livePid = 99999

        let record = SessionStateStore.record(from: snap)

        XCTAssertNil(record.pid)
    }

    func testSnapshotCacheRestoreDropsTransientTerminalIdentity() {
        var snap = makeSnapshot(id: "s1", cwd: "/proj")
        snap.livePid = 99999
        snap.tty = "/dev/ttys001"
        snap.terminalPID = 123
        snap.state = .running
        snap.workState = WorkState(status: .working,
                                   reason: "agent is active",
                                   nextAction: "Watch",
                                   rank: 5)

        let restored = SnapshotDiskCache.restoredSnapshot(snap)

        XCTAssertNil(restored.livePid)
        XCTAssertNil(restored.tty)
        XCTAssertNil(restored.terminalPID)
        XCTAssertEqual(restored.state, .idle)
        XCTAssertEqual(restored.workState.status, .done)
    }

    private func makeSnapshot(id: String, cwd: String) -> SourceSnapshot {
        SourceSnapshot.withDerivedFields(SourceSnapshot(
            id: id,
            tool: "Claude",
            badge: "C",
            state: .running,
            cwd: cwd,
            updatedAt: Date()
        ))
    }
}
