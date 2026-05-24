import AppKit
import Darwin
import Foundation

struct TerminalIdentity: Equatable {
    let bundleID: String
    let appPID: pid_t
    let tty: String?
    let cwd: String?
    let surfaceID: String?
    let windowID: String?
    let tabID: String?
}

enum TerminalIdentityResolver {
    static func focusedTerminal(for target: WindowFinder.Target) -> TerminalIdentity? {
        switch target.bundleID {
        case "com.mitchellh.ghostty":
            return focusedGhosttyIdentity(appPID: target.pid)
        case "com.googlecode.iterm2":
            return focusedITermIdentity(appPID: target.pid)
        case "com.apple.Terminal":
            return focusedTerminalAppIdentity(appPID: target.pid)
        default:
            return nil
        }
    }

    static func resolve(shellPid: pid_t, cwd: String, tty: String?) -> TerminalIdentity? {
        guard let app = owningTerminalApp(forDescendant: shellPid),
              let bundleID = app.bundleIdentifier
        else { return nil }

        let normalizedTTY = normalizeTTY(tty)
        if bundleID == "com.mitchellh.ghostty",
           let ghostty = focusedGhosttyIdentity(app: app, cwd: cwd, tty: normalizedTTY) {
            return ghostty
        }

        return TerminalIdentity(bundleID: bundleID,
                                appPID: app.processIdentifier,
                                tty: normalizedTTY,
                                cwd: cwd,
                                surfaceID: nil,
                                windowID: nil,
                                tabID: nil)
    }

    static func resolve(agentPid: pid_t, cwd: String?) -> TerminalIdentity? {
        guard let app = owningTerminalApp(forDescendant: agentPid),
              let bundleID = app.bundleIdentifier
        else { return nil }

        let tty = processTTY(pid: agentPid)
        return TerminalIdentity(bundleID: bundleID,
                                appPID: app.processIdentifier,
                                tty: tty,
                                cwd: cwd,
                                surfaceID: nil,
                                windowID: nil,
                                tabID: nil)
    }

    private static func owningTerminalApp(forDescendant pid: pid_t) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in running where app.processIdentifier > 0 {
            appsByPID[app.processIdentifier] = app
        }
        var current = pid
        for _ in 0..<48 {
            if let app = appsByPID[current],
               let bid = app.bundleIdentifier,
               WindowFinder.targetBundleIDs.contains(bid) {
                return app
            }
            let parent = parentPID(of: current)
            if parent <= 1 { return nil }
            current = parent
        }
        return nil
    }

    private static func focusedGhosttyIdentity(app: NSRunningApplication,
                                               cwd: String,
                                               tty: String?) -> TerminalIdentity? {
        // The prompt hook runs from the focused terminal surface, so the
        // front-window/focused-terminal query gives us Ghostty's stable surface
        // identity without needing to infer it later from cwd.
        let script = """
        tell application "Ghostty"
            set w to front window
            set t to selected tab of w
            set term to focused terminal of t
            return (id of w) & "|" & (id of t) & "|" & (id of term) & "|" & (working directory of term)
        end tell
        """
        guard let out = runAppleScript(script) else {
            return TerminalIdentity(bundleID: "com.mitchellh.ghostty",
                                    appPID: app.processIdentifier,
                                    tty: tty,
                                    cwd: cwd,
                                    surfaceID: nil,
                                    windowID: nil,
                                    tabID: nil)
        }
        let parts = out.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        let reportedCwd = (parts[3] as NSString).standardizingPath
        let expectedCwd = (cwd as NSString).standardizingPath
        guard reportedCwd == expectedCwd else {
            return TerminalIdentity(bundleID: "com.mitchellh.ghostty",
                                    appPID: app.processIdentifier,
                                    tty: tty,
                                    cwd: cwd,
                                    surfaceID: nil,
                                    windowID: nil,
                                    tabID: nil)
        }
        return TerminalIdentity(bundleID: "com.mitchellh.ghostty",
                                appPID: app.processIdentifier,
                                tty: tty,
                                cwd: cwd,
                                surfaceID: parts[2],
                                windowID: parts[0],
                                tabID: parts[1])
    }

    private static func focusedGhosttyIdentity(appPID: pid_t) -> TerminalIdentity? {
        let script = """
        tell application "Ghostty"
            set w to front window
            set t to selected tab of w
            set term to focused terminal of t
            return (id of w) & "|" & (id of t) & "|" & (id of term) & "|" & (working directory of term)
        end tell
        """
        guard let out = runAppleScript(script) else { return nil }
        let parts = out.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        return TerminalIdentity(bundleID: "com.mitchellh.ghostty",
                                appPID: appPID,
                                tty: nil,
                                cwd: parts[3],
                                surfaceID: parts[2],
                                windowID: parts[0],
                                tabID: parts[1])
    }

    private static func focusedITermIdentity(appPID: pid_t) -> TerminalIdentity? {
        let script = """
        tell application "iTerm2"
            set s to current session of current window
            return (tty of s) & "|" & (name of s) & "|" & (id of current tab of current window)
        end tell
        """
        guard let out = runAppleScript(script) else { return nil }
        let parts = out.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        return TerminalIdentity(bundleID: "com.googlecode.iterm2",
                                appPID: appPID,
                                tty: normalizeTTY(parts[0]),
                                cwd: nil,
                                surfaceID: nil,
                                windowID: nil,
                                tabID: parts.count > 2 ? parts[2] : nil)
    }

    private static func focusedTerminalAppIdentity(appPID: pid_t) -> TerminalIdentity? {
        let script = """
        tell application "Terminal"
            set t to selected tab of front window
            return (tty of t) & "|" & (custom title of t)
        end tell
        """
        guard let out = runAppleScript(script) else { return nil }
        let parts = out.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        return TerminalIdentity(bundleID: "com.apple.Terminal",
                                appPID: appPID,
                                tty: normalizeTTY(parts[0]),
                                cwd: nil,
                                surfaceID: nil,
                                windowID: nil,
                                tabID: nil)
    }

    private static func runAppleScript(_ script: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            let deadline = Date().addingTimeInterval(1.5)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if task.isRunning {
                task.terminate()
                return nil
            }
            guard task.terminationStatus == 0 else { return nil }
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func normalizeTTY(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "not a tty"
        else { return nil }
        return value.hasPrefix("/dev/") ? value : "/dev/\(value)"
    }

    static func processTTY(pid: pid_t) -> String? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let probe = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probe > 0 else { return nil }
        let count = Int(probe) / stride + 32
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(count * stride))
        guard n > 0 else { return nil }
        for i in 0..<Int(n) / stride {
            guard fds[i].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var vi = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, Int32(fds[i].proc_fd),
                                   PROC_PIDFDVNODEPATHINFO,
                                   &vi,
                                   Int32(MemoryLayout<vnode_fdinfowithpath>.stride))
            guard r > 0 else { continue }
            let path = withUnsafePointer(to: &vi.pvip.vip_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if path.hasPrefix("/dev/tty") { return path }
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 { return 0 }
        var info = kinfo_proc()
        size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) != 0 { return 0 }
        return info.kp_eproc.e_ppid
    }
}
