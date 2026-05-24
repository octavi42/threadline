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
            for _ in 0..<120 {      // up to ~6s (launchd may throttle restarts)
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
        var sendArgs = args
        if (cmd == "show" || cmd == "toggle"),
           !sendArgs.contains("--cwd") {
            sendArgs.append(contentsOf: ["--cwd", FileManager.default.currentDirectoryPath])
        }
        if !sendArgs.isEmpty { payload += " " + sendArgs.joined(separator: " ") }
        IPC.writeLine(fd, payload)
        // Multi-line daemon replies must use readAll so output isn't truncated.
        if cmd == "list" || cmd == "jump-debug" || cmd == "focus-debug" {
            if let reply = IPC.readAll(fd) { print(reply) }
        } else if let reply = IPC.readLine(fd) {
            print(reply)
        }
    }

    private static func spawnDaemon() -> Bool {
        cleanupStaleDaemonArtifacts()
        if LaunchAgent.isInstalled, kickstartLaunchAgent() {
            return true
        }
        return spawnDetachedDaemon()
    }

    private static func spawnDetachedDaemon() -> Bool {
        guard let fullPath = Bundle.main.executablePath else {
            FileHandle.standardError.write(Data("could not resolve executable path\n".utf8))
            return false
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

    private static func kickstartLaunchAgent() -> Bool {
        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(uid)/\(LaunchAgent.label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Drop stale lock/socket left by a crashed or recently quit daemon.
    private static func cleanupStaleDaemonArtifacts() {
        if let pid = DaemonLock.holderPID(), pid > 0, kill(pid, 0) == 0 {
            return
        }
        try? FileManager.default.removeItem(atPath: DaemonLock.lockPath)
        try? FileManager.default.removeItem(atPath: IPC.socketPath)
    }
}
