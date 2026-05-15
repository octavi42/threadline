import AppKit
import Darwin
import Foundation

enum JumpBack {
    struct Result {
        let appName: String
        let exactTab: Bool
        let detail: String
    }

    static func jump(to snapshot: SourceSnapshot?) -> Result? {
        guard let snapshot = snapshot else { return nil }

        if snapshot.tool == "Cursor" {
            return activateCursor(cwd: snapshot.cwd)
        }

        guard let app = app(for: snapshot)
        else { return nil }

        let focus = focusExactTabIfPossible(bundleID: snapshot.terminalBundleID ?? app.bundleIdentifier,
                                            tty: snapshot.tty,
                                            cwd: snapshot.cwd,
                                            surfaceID: snapshot.terminalSurfaceID)
        app.activate(options: [.activateIgnoringOtherApps])
        let route = [
            "pid=\(snapshot.livePid.map(String.init) ?? "-")",
            "bundle=\(snapshot.terminalBundleID ?? app.bundleIdentifier ?? "-")",
            "tty=\(snapshot.tty ?? "-")",
            "surface=\(snapshot.terminalSurfaceID ?? "-")",
            "cwd=\(snapshot.cwd ?? "-")",
        ].joined(separator: " ")
        return Result(appName: app.localizedName ?? app.bundleIdentifier ?? "app",
                      exactTab: focus.exact,
                      detail: "\(focus.detail) \(route)")
    }

    private static func app(for snapshot: SourceSnapshot) -> NSRunningApplication? {
        if let pid = snapshot.terminalPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            return app
        }
        guard let agentPid = snapshot.livePid else { return nil }
        return owningApp(forDescendant: agentPid)
    }

    private static func owningApp(forDescendant pid: pid_t) -> NSRunningApplication? {
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

    private static func activateCursor(cwd: String?) -> Result? {
        let cursorBundleIDs: Set<String> = [
            "com.todesktop.230313mzl4w4u92",
            "com.todesktop.230313mzl4w4u92-insider",
        ]
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier.map(cursorBundleIDs.contains) ?? false
        }) {
            app.activate(options: [.activateIgnoringOtherApps])
            return Result(appName: app.localizedName ?? "Cursor",
                          exactTab: false,
                          detail: "app")
        }
        guard let cwd = cwd else { return nil }
        for bundleID in cursorBundleIDs {
            if openWorkspace(cwd: cwd, bundleID: bundleID) {
                return Result(appName: "Cursor", exactTab: false, detail: "workspace")
            }
        }
        return nil
    }

    private static func openWorkspace(cwd: String, bundleID: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", bundleID, (cwd as NSString).standardizingPath]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    private static func focusExactTabIfPossible(bundleID: String?,
                                                tty: String?,
                                                cwd: String?,
                                                surfaceID: String?) -> (exact: Bool, detail: String) {
        guard let bundleID = bundleID,
              !bundleID.isEmpty
        else { return (false, "app") }

        switch bundleID {
        case "com.apple.Terminal":
            guard let tty = tty, !tty.isEmpty else { return (false, "app") }
            return runAppleScript(terminalScript(tty: tty)) ? (true, "tty") : (false, "app")
        case "com.googlecode.iterm2":
            guard let tty = tty, !tty.isEmpty else { return (false, "app") }
            return runAppleScript(iTermScript(appName: "iTerm2", tty: tty)) ? (true, "tty") : (false, "app")
        case "com.googlecode.iterm2.beta":
            guard let tty = tty, !tty.isEmpty else { return (false, "app") }
            return runAppleScript(iTermScript(appName: "iTerm", tty: tty)) ? (true, "tty") : (false, "app")
        case "com.mitchellh.ghostty":
            if let surfaceID = surfaceID, !surfaceID.isEmpty,
               runAppleScript(ghosttySurfaceScript(surfaceID: surfaceID)) {
                return (true, "surface-id")
            }
            guard let cwd = cwd, !cwd.isEmpty else { return (false, "app") }
            return runAppleScript(ghosttyCwdScript(cwd: (cwd as NSString).standardizingPath))
                ? (true, "cwd")
                : (false, "app")
        default:
            return (false, "app")
        }
    }

    private static func terminalScript(tty: String) -> String {
        let tty = appleScriptString(tty)
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not found"
        """
    }

    private static func iTermScript(appName: String, tty: String) -> String {
        let appName = appleScriptString(appName)
        let tty = appleScriptString(tty)
        return """
        tell application "\(appName)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select t
                            select w
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not found"
        """
    }

    private static func ghosttySurfaceScript(surfaceID: String) -> String {
        let surfaceID = appleScriptString(surfaceID)
        return """
        tell application "Ghostty"
            repeat with term in terminals
                if id of term is "\(surfaceID)" then
                    focus term
                    activate
                    return "ok"
                end if
            end repeat
        end tell
        return "not found"
        """
    }

    private static func ghosttyCwdScript(cwd: String) -> String {
        let cwd = appleScriptString(cwd)
        return """
        tell application "Ghostty"
            repeat with term in terminals
                if working directory of term is "\(cwd)" then
                    focus term
                    activate
                    return "ok"
                end if
            end repeat
        end tell
        return "not found"
        """
    }

    private static func runAppleScript(_ script: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let deadline = Date().addingTimeInterval(5.0)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if task.isRunning {
                task.terminate()
                return false
            }
            guard task.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            return out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
        } catch {
            return false
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
