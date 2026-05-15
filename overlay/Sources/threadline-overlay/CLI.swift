import Foundation
import Darwin

enum CLI {
    /// Fire-and-forget shell hook ping. Must be FAST and silent on failure —
    /// it runs on every prompt. Does not auto-spawn the daemon: if no daemon
    /// is listening, the touch is dropped.
    static func touch(args: [String]) {
        var cwd: String?
        var pid: Int?
        var tty: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "--cwd": cwd = next; i += 2
            case "--pid": pid = next.flatMap(Int.init); i += 2
            case "--tty": tty = next; i += 2
            default:      i += 1
            }
        }
        guard let cwd = cwd, let pid = pid else {
            // Silently exit on malformed args — don't break prompts.
            return
        }
        let fd = IPC.connect()
        if fd < 0 { return }
        defer { close(fd) }
        var obj: [String: Any] = ["cwd": cwd, "pid": pid]
        if let tty = tty { obj["tty"] = tty }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        IPC.writeLine(fd, "touch \(json)")
        // Wait briefly for ack to keep the socket buffered, then exit.
        _ = IPC.readLine(fd)
    }

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
        // `list` returns multi-line output; everything else is one line. Use
        // readAll so multi-line replies aren't truncated.
        if cmd == "list" {
            if let reply = IPC.readAll(fd) { print(reply) }
        } else if let reply = IPC.readLine(fd) {
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
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            return true
        } catch {
            FileHandle.standardError.write(Data("spawn failed: \(error)\n".utf8))
            return false
        }
    }
}
