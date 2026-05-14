import Foundation
import Darwin

enum IPC {
    static let socketPath: String = {
        if let override = ProcessInfo.processInfo.environment["THREADLINE_OVERLAY_SOCKET"],
           !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.threadline/overlay.sock"
    }()

    static func ensureSocketDir() {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
    }

    private static func fillSunPath(_ addr: inout sockaddr_un, _ path: String) -> Bool {
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { cptr in
                for (i, b) in bytes.enumerated() { cptr[i] = CChar(b) }
                cptr[bytes.count] = 0
            }
        }
        return true
    }

    /// Open a connected client socket. Returns -1 on failure.
    static func connect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard fillSunPath(&addr, socketPath) else { close(fd); return -1 }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }

    /// Bind+listen for the server. Returns -1 on failure.
    static func listen() -> Int32 {
        ensureSocketDir()
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard fillSunPath(&addr, socketPath) else { close(fd); return -1 }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size)
            }
        }
        if bindRes != 0 { close(fd); return -1 }
        if Darwin.listen(fd, 8) != 0 { close(fd); return -1 }
        chmod(socketPath, 0o600)
        return fd
    }

    static func writeLine(_ fd: Int32, _ s: String) {
        let line = s + "\n"
        line.withCString { ptr in
            _ = Darwin.send(fd, ptr, strlen(ptr), 0)
        }
    }

    /// Read until socket close. For multi-line replies like `list`.
    static func readAll(_ fd: Int32) -> String? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        if buf.isEmpty { return nil }
        if buf.last == 0x0A { buf.removeLast() }
        return String(decoding: buf, as: UTF8.self)
    }

    /// Read until newline or EOF. Returns trimmed line, or nil on EOF/err.
    static func readLine(_ fd: Int32) -> String? {
        var buf = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n <= 0 { return buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self) }
            if byte == 0x0A { break }
            buf.append(byte)
        }
        return String(decoding: buf, as: UTF8.self)
    }
}
