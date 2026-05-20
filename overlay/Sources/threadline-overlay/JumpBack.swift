import AppKit
import Darwin
import Foundation

enum JumpBack {
    struct Result {
        let appName: String
        let exactTab: Bool
        let detail: String
    }

    private static let cursorBundleIDs: Set<String> = [
        "com.todesktop.230313mzl4w4u92",
        "com.todesktop.230313mzl4w4u92-insider",
    ]

    static func canJump(to snapshot: SourceSnapshot?) -> Bool {
        guard let snapshot = snapshot else { return false }
        if snapshot.tool == "Cursor" {
            if runningCursorApp() != nil { return true }
            guard let cwd = snapshot.cwd, !cwd.isEmpty else { return false }
            return cursorIsInstalled()
        }
        guard let app = app(for: snapshot),
              let bundleID = snapshot.terminalBundleID ?? app.bundleIdentifier
        else { return false }
        return hasTerminalRoute(bundleID: bundleID, snapshot: snapshot)
    }

    static func jumpLabel(for snapshot: SourceSnapshot) -> String {
        if snapshot.tool == "Cursor" { return "Open Cursor workspace" }
        if let bundleID = snapshot.terminalBundleID {
            switch bundleID {
            case "com.mitchellh.ghostty":
                if let surfaceID = snapshot.terminalSurfaceID, !surfaceID.isEmpty {
                    return "Open Ghostty terminal"
                }
                if let cwd = snapshot.cwd, !cwd.isEmpty {
                    return "Open Ghostty terminal if project path is unique"
                }
                return "No Ghostty terminal identity yet"
            case "com.apple.Terminal",
                 "com.googlecode.iterm2",
                 "com.googlecode.iterm2.beta":
                if let tty = snapshot.tty, !tty.isEmpty {
                    return "Open terminal tab"
                }
                return "No exact terminal TTY yet"
            default:
                return "Exact jump is not supported for this terminal"
            }
        }
        return "No terminal identity yet"
    }

    static func jump(to snapshot: SourceSnapshot?) -> Result? {
        guard let snapshot = snapshot else { return nil }

        if snapshot.tool == "Cursor" {
            return activateCursor(cwd: snapshot.cwd)
        }

        guard let app = app(for: snapshot)
        else { return nil }

        let bundleID = snapshot.terminalBundleID ?? app.bundleIdentifier
        guard hasTerminalRoute(bundleID: bundleID, snapshot: snapshot) else { return nil }

        let focus = focusExactTabIfPossible(bundleID: bundleID,
                                            tty: snapshot.tty,
                                            cwd: snapshot.cwd,
                                            titleHint: ghosttyTitleHint(for: snapshot),
                                            surfaceID: snapshot.terminalSurfaceID)
        let route = [
            "pid=\(snapshot.livePid.map(String.init) ?? "-")",
            "bundle=\(snapshot.terminalBundleID ?? app.bundleIdentifier ?? "-")",
            "tty=\(snapshot.tty ?? "-")",
            "surface=\(snapshot.terminalSurfaceID ?? "-")",
            "cwd=\(snapshot.cwd ?? "-")",
        ].joined(separator: " ")
        guard focus.exact else {
            return Result(appName: app.localizedName ?? app.bundleIdentifier ?? "app",
                          exactTab: false,
                          detail: "\(focus.detail) \(route)")
        }
        app.activate(options: [.activateIgnoringOtherApps])
        return Result(appName: app.localizedName ?? app.bundleIdentifier ?? "app",
                      exactTab: focus.exact,
                      detail: "\(focus.detail) \(route)")
    }

    private static func hasTerminalRoute(bundleID: String?,
                                         snapshot: SourceSnapshot) -> Bool {
        guard let bundleID = bundleID else { return false }
        switch bundleID {
        case "com.apple.Terminal",
             "com.googlecode.iterm2",
             "com.googlecode.iterm2.beta":
            return !(snapshot.tty ?? "").isEmpty
        case "com.mitchellh.ghostty":
            return !(snapshot.terminalSurfaceID ?? "").isEmpty || !(snapshot.cwd ?? "").isEmpty
        default:
            return false
        }
    }

    private static func ghosttyTitleHint(for snapshot: SourceSnapshot) -> String? {
        guard snapshot.terminalBundleID == "com.mitchellh.ghostty" else { return nil }
        let raw = snapshot.currentTask
            ?? snapshot.jsonlPath.flatMap(Summarizer.extractOpeningGoal)
            ?? snapshot.lastText
        guard let raw = raw else { return nil }
        let compact = SourceSnapshot.compactLine(raw, limit: 80, maxWords: 12, firstSentence: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty || compact == "—" ? nil : compact
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

    private static func runningCursorApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier.map(cursorBundleIDs.contains) ?? false
        }
    }

    private static func cursorIsInstalled() -> Bool {
        cursorBundleIDs.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    private static func activateCursor(cwd: String?) -> Result? {
        if let app = runningCursorApp() {
            app.activate(options: [.activateIgnoringOtherApps])
            return Result(appName: app.localizedName ?? "Cursor",
                          exactTab: true,
                          detail: "app")
        }
        guard let cwd = cwd else { return nil }
        for bundleID in cursorBundleIDs {
            if openWorkspace(cwd: cwd, bundleID: bundleID) {
                return Result(appName: "Cursor", exactTab: true, detail: "workspace")
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
                                                titleHint: String?,
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
            guard let cwd = cwd, !cwd.isEmpty else { return (false, "missing-surface-id") }
            if let titleHint = titleHint, !titleHint.isEmpty,
               runAppleScript(ghosttyTitleAndCwdScript(cwd: (cwd as NSString).standardizingPath,
                                                       titleHint: titleHint)) {
                return (true, "title+cwd")
            }
            return runAppleScript(ghosttyUniqueCwdScript(cwd: (cwd as NSString).standardizingPath))
                ? (true, "unique-cwd")
                : (false, "ambiguous-or-missing-cwd")
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

    private static func ghosttyUniqueCwdScript(cwd: String) -> String {
        let cwd = appleScriptString(cwd)
        return """
        tell application "Ghostty"
            set matches to {}
            repeat with term in terminals
                if working directory of term is "\(cwd)" then
                    set end of matches to term
                end if
            end repeat
            if (count of matches) is 1 then
                focus item 1 of matches
                activate
                return "ok"
            end if
        end tell
        return "not found"
        """
    }

    private static func ghosttyTitleAndCwdScript(cwd: String, titleHint: String) -> String {
        let cwd = appleScriptString(cwd)
        let titleHint = appleScriptString(titleHint)
        return """
        tell application "Ghostty"
            set matches to {}
            repeat with term in terminals
                if working directory of term is "\(cwd)" and name of term contains "\(titleHint)" then
                    set end of matches to term
                end if
            end repeat
            if (count of matches) is 1 then
                focus item 1 of matches
                activate
                return "ok"
            end if
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
