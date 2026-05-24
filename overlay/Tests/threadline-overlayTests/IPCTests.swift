import Darwin
import XCTest
@testable import threadline_overlay

final class IPCTests: XCTestCase {
    func testWriteLineDoesNotTerminateProcessWhenPeerDisconnected() {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets[0] >= 0, sockets[1] >= 0 else { return }
        defer { close(sockets[0]) }

        close(sockets[1])
        IPC.writeLine(sockets[0], "reply")
    }
}
