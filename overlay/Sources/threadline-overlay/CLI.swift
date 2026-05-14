import Foundation
import Darwin

enum CLI {
    /// Send a one-line command to the daemon. If no daemon is running:
    ///   • if the LaunchAgent isn't installed yet, run install (which bootstraps it)
    ///   • otherwise, spawn a foreground daemon
    /// Then retry the connection.
    static func send(_ cmd: String, args: [String]) {
        var fd = IPC.connect()
        if fd < 0 {
            if !LaunchAgent.isInstalled {
                fputs("first run: installing threadline-overlay LaunchAgent…\n", stderr)
                LaunchAgent.install()
            } else if !spawnDaemon() {
                FileHandle.standardError.write(Data("could not start daemon\n".utf8))
                exit(1)
            }
            for _ in 0..<60 {       // up to ~3s
                usleep(50_000)
                fd = IPC.connect()
                if fd >= 0 { break }
            }
            if fd < 0 {
                FileHandle.standardError.write(Data("daemon did not come up\n".utf8))
                exit(1)
            }
        }
        defer { close(fd) }
        var payload = cmd
        if !args.isEmpty { payload += " " + args.joined(separator: " ") }
        IPC.writeLine(fd, payload)
        if let reply = IPC.readLine(fd) {
            print(reply)
        }
    }

    private static func spawnDaemon() -> Bool {
        let exe = CommandLine.arguments[0]
        // Resolve to absolute path so the spawn survives wherever we ran from.
        let resolved = (exe as NSString).expandingTildeInPath
        let fullPath: String
        if resolved.hasPrefix("/") {
            fullPath = resolved
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            fullPath = (cwd as NSString).appendingPathComponent(resolved)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: fullPath)
        task.arguments = ["daemon"]
        task.standardInput = nil
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
            return true
        } catch {
            FileHandle.standardError.write(Data("spawn failed: \(error)\n".utf8))
            return false
        }
    }
}
