import XCTest
@testable import threadline_overlay

final class JumpBackTests: XCTestCase {
    func testResolveRoutePrefersTerminalForCursorAgentWithTTY() throws {
        try requireLiveTest()
        let sessions = LiveAgents.liveSessions().filter { $0.tool == "Cursor" }
        try XCTSkipIf(sessions.isEmpty, "No live Cursor agents")

        var terminalRouted = 0
        for session in sessions {
            guard var snap = CursorAgentSource.snapshot(forJSONL: session.jsonlPath) else { continue }
            snap.livePid = session.pid
            let route = JumpBack.resolveRoute(for: snap)
            let tty = TerminalIdentityResolver.processTTY(pid: session.pid)
            if tty != nil {
                XCTAssertEqual(route.kind, .terminal,
                               "cursor-agent pid \(session.pid) has tty \(tty!) but route=\(route.kind)")
                XCTAssertNotNil(route.bundleID)
                XCTAssertNotNil(route.tty)
                terminalRouted += 1
            }
        }
        print("CURSOR_TERMINAL_ROUTES \(terminalRouted)/\(sessions.count)")
    }

    func testCanJumpUsesResolvedTerminalRoute() throws {
        try requireLiveTest()
        guard let session = LiveAgents.liveSessions().first(where: { $0.tool == "Cursor" }) else {
            throw XCTSkip("No live Cursor agents")
        }
        guard var snap = CursorAgentSource.snapshot(forJSONL: session.jsonlPath) else {
            XCTFail("missing snapshot")
            return
        }
        snap.livePid = session.pid
        let route = JumpBack.resolveRoute(for: snap)
        if route.kind == .terminal {
            XCTAssertTrue(JumpBack.canJump(to: snap))
            XCTAssertTrue(JumpBack.jumpLabel(for: snap).contains("Ghostty")
                          || JumpBack.jumpLabel(for: snap).contains("terminal"))
        }
    }

    func testDryRunDoesNotRequireAppleScriptSuccess() throws {
        try requireLiveTest()
        guard let session = LiveAgents.liveSessions().first(where: { $0.tool == "Cursor" }) else {
            throw XCTSkip("No live Cursor agents")
        }
        guard var snap = CursorAgentSource.snapshot(forJSONL: session.jsonlPath) else {
            XCTFail("missing snapshot")
            return
        }
        snap.livePid = session.pid
        let result = JumpBack.jump(to: snap, dryRun: true)
        XCTAssertNotNil(result)
        if JumpBack.resolveRoute(for: snap).kind == .terminal {
            XCTAssertTrue(result?.exactTab == true)
        }
    }

    func testRegisteredShellGetsGhosttySurface() throws {
        try requireLiveTest()
        guard let session = LiveAgents.liveSessions().first(where: { $0.tool == "Cursor" }) else {
            throw XCTSkip("No live Cursor agents")
        }
        guard var snap = CursorAgentSource.snapshot(forJSONL: session.jsonlPath) else {
            XCTFail("missing snapshot")
            return
        }
        snap.livePid = session.pid
        let route = JumpBack.resolveRoute(for: snap)
        let tty = TerminalIdentityResolver.processTTY(pid: session.pid)
        let hasRegistry = tty.flatMap { ShellRegistry.shared.terminalIdentity(matchingTTY: $0)?.surfaceID } != nil
        if hasRegistry {
            XCTAssertNotNil(route.surfaceID, "expected surface id from shell registry for pid \(session.pid)")
        }
    }

    private func requireLiveTest() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["THREADLINE_LIVE_TEST"] != "1",
                      "Set THREADLINE_LIVE_TEST=1 to run jump-back live tests")
    }
}
